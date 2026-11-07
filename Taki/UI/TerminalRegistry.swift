import SwiftTerm
import SwiftUI

/// Keeps each tab's terminal (and its shell) alive while you switch tabs or screens.
@MainActor
final class TerminalRegistry {
    static let shared = TerminalRegistry()
    private var views: [UUID: LocalProcessTerminalView] = [:]
    private var delegates: [UUID: TerminalDelegate] = [:]
    private var folders: [UUID: String] = [:]

    func view(for tab: TerminalTab, model: AppModel) -> LocalProcessTerminalView {
        if let v = views[tab.id] { return v }
        let v = TakiTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        v.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        v.nativeBackgroundColor = Theme.terminalNSBackground
        v.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        v.caretColor = NSColor(srgbRed: 0.51, green: 0.66, blue: 1, alpha: 1)
        let id = tab.id
        v.currentFolder = { [weak self] in self?.folders[id] }
        let delegate = TerminalDelegate(id: tab.id, model: model)
        delegates[tab.id] = delegate
        v.processDelegate = delegate
        var env = ShellEnvironment.load()
        env["TERM_PROGRAM"] = "Taki"
        // SwiftTerm supports synchronized output (DEC mode 2026), which Claude Code does not
        // detect in a terminal it does not know; with it each redraw lands at once, no flicker.
        env["CLAUDE_CODE_FORCE_SYNC_OUTPUT"] = env["CLAUDE_CODE_FORCE_SYNC_OUTPUT"] ?? "1"
        let shell = env["SHELL"] ?? "/bin/zsh"
        var args = ["-l"]
        // A command tab runs its command, then stays open as a normal shell when it ends.
        if let command = tab.command { args += ["-c", command + "; exec \(shell) -l"] }
        v.startProcess(executable: shell, args: args, environment: env.map { "\($0.key)=\($0.value)" },
                       execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: tab.folder)
        views[tab.id] = v
        folders[tab.id] = tab.folder
        return v
    }

    /// The tab's terminal if it has been opened (for dictation and other input from the toolbar).
    func existingView(_ id: UUID) -> TakiTerminalView? { views[id] as? TakiTerminalView }

    func remove(_ id: UUID) {
        views[id]?.terminate()
        views[id] = nil
        delegates[id] = nil
        folders[id] = nil
    }

    func focus(_ id: UUID) {
        guard let v = views[id] else { return }
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
    }

    /// The folder the tab's shell is in now (reported by the shell through OSC 7), else its start folder.
    func currentFolder(of id: UUID) -> String? { folders[id] }

    func moved(_ id: UUID, to folder: String) { folders[id] = folder }

    /// True when the tab's shell is running something (a Claude session, a build, a server).
    /// A child that already ended (no path any more) and the shell's own helpers do not count.
    func isBusy(_ id: UUID, parents: [Int32: Int32]) -> Bool {
        guard let pid = views[id]?.process?.shellPid, pid > 0 else { return false }
        return ProcessScanner.descendants(of: pid, parents: parents).contains { child in
            let path = ProcessScanner.path(of: child)
            return !path.isEmpty && !Self.isShellHelper((path as NSString).lastPathComponent)
        }
    }

    /// Helpers a shell keeps running on its own (prompt themes, env loaders, async prompt workers,
    /// which run as another copy of the shell): not "your" work.
    static let shellHelpers = ["gitstatusd", "direnv", "zsh-autosuggest", "starship", "atuin"]
    static let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", "dash"]

    static func isShellHelper(_ name: String) -> Bool {
        shellNames.contains(name) || shellHelpers.contains { name.hasPrefix($0) }
    }

    /// Each tab's shell pid, so the poll can read where every shell is right now (`cd` is seen even
    /// when the shell does not report it) off the main thread.
    func shellPids() -> [UUID: Int32] {
        var out: [UUID: Int32] = [:]
        for (id, v) in views {
            if let pid = v.process?.shellPid, pid > 0 { out[id] = pid }
        }
        return out
    }

    /// The tab whose shell started `pid` (directly or further down), if any.
    func tab(containing pid: Int32, parents: [Int32: Int32]) -> UUID? {
        for (id, v) in views {
            let shell = v.process?.shellPid ?? 0
            if shell > 0, pid == shell || ProcessScanner.isDescendant(pid, of: shell, parents: parents) { return id }
        }
        return nil
    }
}

final class TerminalDelegate: NSObject, LocalProcessTerminalViewDelegate {
    let id: UUID
    weak var model: AppModel?
    init(id: UUID, model: AppModel) { self.id = id; self.model = model }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL || directory.hasPrefix("/") else { return }
        let path = url.isFileURL ? url.path : directory
        let id = id
        Task { @MainActor [weak model] in
            TerminalRegistry.shared.moved(id, to: path)
            model?.terminalMoved(id, to: path)
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let id = id
        Task { @MainActor [weak model] in model?.closeTerminal(id) }
    }
}

struct TerminalHost: NSViewRepresentable {
    let tab: TerminalTab
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if container.subviews.first !== TerminalRegistry.shared.view(for: tab, model: model) {
            container.subviews.forEach { $0.removeFromSuperview() }
            attach(to: container)
        }
    }

    private func attach(to container: NSView) {
        let v = TerminalRegistry.shared.view(for: tab, model: model)
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        TerminalRegistry.shared.focus(tab.id)
    }
}
