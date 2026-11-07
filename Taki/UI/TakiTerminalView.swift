import AppKit
import Carbon.HIToolbox
import SwiftTerm

/// Taki's terminal: SwiftTerm's local-process view plus what agent sessions need from a Mac
/// terminal. Drop files or images on it to type their paths into the prompt (how Claude Code
/// and Codex take screenshots), and Shift-Return inserts a new line in an agent's prompt.
final class TakiTerminalView: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.droppedPaths(from: sender.draggingPasteboard, imageFolder: nil).isEmpty
            && !Self.hasImage(sender.draggingPasteboard) ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = Self.droppedPaths(from: sender.draggingPasteboard, imageFolder: Self.imageFolder)
        guard let text = Self.typedText(for: paths) else { return false }
        send(txt: text)
        window?.makeFirstResponder(self)
        return true
    }

    /// File paths on the pasteboard; an image with no file behind it (dragged out of a browser or
    /// a screenshot thumbnail) is written to `imageFolder` first so the agent can read it.
    static func droppedPaths(from pasteboard: NSPasteboard, imageFolder: URL?) -> [String] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return urls.map(\.path) }
        guard let folder = imageFolder, let data = pngData(from: pasteboard) else { return [] }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appending(path: "image-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        guard fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return [] }
        return [file.path]
    }

    static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Where dropped images without a file are kept: Taki's own temporary folder, private to the
    /// owner, emptied of anything older than a day at launch (`pruneDroppedImages`).
    static var imageFolder: URL { FileManager.default.temporaryDirectory.appending(path: "TakiDrops") }

    static func pruneDroppedImages(olderThan age: TimeInterval = 86_400, now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: imageFolder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for f in files {
            let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(modified) > age { try? fm.removeItem(at: f) }
        }
    }

    /// Paths as one line of shell-safe words with a trailing space, never a Return: the owner
    /// decides when to send. The text is typed as keystrokes, so a path with a control character
    /// (a Return, Ctrl-C or Escape hidden in a file name) is left out: quoting cannot stop those.
    /// Nil when nothing safe is left.
    static func typedText(for paths: [String]) -> String? {
        let safe = paths.filter { !$0.isEmpty && !$0.unicodeScalars.contains(where: isControl) }
        return safe.isEmpty ? nil : safe.map(shellQuoted).joined(separator: " ") + " "
    }

    /// C0 controls, DEL and C1 controls.
    static func isControl(_ s: Unicode.Scalar) -> Bool {
        s.value < 0x20 || (0x7F...0x9F).contains(s.value)
    }

    static func shellQuoted(_ path: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+@%:,"))
        if !path.isEmpty, path.unicodeScalars.allSatisfy(plain.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Opening file:line links

    /// Where the tab's shell is now, so a relative path an agent prints resolves correctly.
    var currentFolder: () -> String? = { nil }

    /// Cmd-click on `src/app.ts:42` (or an absolute path) opens it in the editor chosen in Settings
    /// at that line. Web links keep SwiftTerm's own checked handling.
    override func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        if let file = FileLink.parse(request.link, cwd: currentFolder() ?? NSHomeDirectory()) {
            FileLink.open(file, in: EditorChoice.current)
        } else {
            super.requestOpenLink(source: source, request: request)
        }
    }

    // MARK: Shift-Return

    /// Shift-Return sends a line feed (the Ctrl-J that Claude Code, Codex and other agent CLIs
    /// read as "new line in the prompt"). A shell reads a line feed as Return, so nothing changes
    /// there. Installed once for the app; it only acts on Taki's own terminals.
    @MainActor static func installShiftReturn() {
        guard shiftReturnMonitor == nil else { return }
        shiftReturnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isShiftReturn(keyCode: event.keyCode, flags: event.modifierFlags),
                  let view = event.window?.firstResponder as? TakiTerminalView else { return event }
            view.send([0x0A])
            return nil
        }
    }

    @MainActor private static var shiftReturnMonitor: Any?

    /// Return or keypad Enter with Shift and no other modifier.
    static func isShiftReturn(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let mods = flags.intersection([.shift, .command, .option, .control])
        let enter = keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter)
        return enter && mods == .shift
    }
}

/// A file location printed in terminal output: `path`, `path:line` or `path:line:column`.
struct FileLink: Equatable {
    let path: String
    let line: Int?
    let column: Int?

    /// Nil for web links and for anything that is not a plain document on this Mac. Output is
    /// untrusted (a cloned repo or an OSC 8 link can name any path), so folders, app bundles,
    /// installers, scripts and executables never count: a click must never launch something.
    static func parse(_ text: String, cwd: String, isDocument: (String) -> Bool = FileLink.isPlainDocument) -> FileLink? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // As printed first (a Next.js route like app/[slug]/page.tsx keeps its brackets), then
        // without the quotes, brackets and commas that prose wraps around a path.
        for candidate in [raw, raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`()[]<>,"))] {
            if let link = location(candidate, cwd: cwd, isDocument: isDocument) { return link }
        }
        return nil
    }

    private static func location(_ text: String, cwd: String, isDocument: (String) -> Bool) -> FileLink? {
        var t = text
        if t.hasPrefix("file://") { t = URL(string: t)?.path ?? String(t.dropFirst(7)) }
        guard !t.isEmpty, !t.contains("://") else { return nil }
        while t.hasSuffix(":") || t.hasSuffix(".") { t.removeLast() }     // "app.ts:42:" from compilers
        var numbers: [Int] = []
        while numbers.count < 2, let colon = t.lastIndex(of: ":") {
            let digits = t[t.index(after: colon)...]
            guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), let n = Int(digits), n > 0 else { break }
            numbers.insert(n, at: 0)
            t = String(t[..<colon])
        }
        if t.hasPrefix("~/") { t = NSHomeDirectory() + t.dropFirst(1) }
        let path = t.hasPrefix("/") ? t : (cwd as NSString).appendingPathComponent(t)
        let clean = (path as NSString).standardizingPath
        guard isDocument(clean) else { return nil }
        return FileLink(path: clean, line: numbers.first, column: numbers.count > 1 ? numbers[1] : nil)
    }

    /// Extensions macOS runs or installs when opened.
    static let launchable: Set<String> = ["app", "bundle", "framework", "xpc", "appex", "plugin", "kext", "prefpane",
                                          "command", "terminal", "tool", "workflow", "action", "scpt", "scptd",
                                          "applescript", "pkg", "mpkg", "dmg", "webloc", "inetloc", "url", "fileloc",
                                          "sh", "zsh", "bash", "fish", "csh", "py", "rb", "pl", "jar", "mobileconfig"]

    /// A regular file, not executable, with no launchable extension.
    static func isPlainDocument(_ path: String) -> Bool {
        let fm = FileManager.default
        guard let type = try? fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType, type == .typeRegular else { return false }
        return !fm.isExecutableFile(atPath: path) && !launchable.contains((path as NSString).pathExtension.lowercased())
    }

    /// The editor's own "open at line" link when it has one; nil for editors without one.
    static func url(for link: FileLink, in editor: EditorChoice) -> URL? {
        let scheme: String
        switch editor {
        case .cursor: scheme = "cursor"
        case .vscode: scheme = "vscode"
        case .zed: scheme = "zed"
        case .xcode, .finder: return nil
        }
        let suffix = link.line.map { ":\($0)" + (link.column.map { ":\($0)" } ?? "") } ?? ""
        let encoded = link.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? link.path
        return URL(string: "\(scheme)://file\(encoded)\(suffix)")
    }

    /// Never through the file's default handler: the editor's link, Xcode itself, or Finder
    /// showing the file.
    @MainActor static func open(_ link: FileLink, in editor: EditorChoice) {
        let file = URL(fileURLWithPath: link.path)
        if let url = url(for: link, in: editor) {
            NSWorkspace.shared.open(url)
        } else if editor == .xcode, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.rawValue) {
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }
}
