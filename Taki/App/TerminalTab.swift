import Foundation

/// What a terminal tab runs. The command line for each kind is fixed here, so nothing else (a
/// saved file, a title) ever decides what a tab executes.
enum TabKind: Equatable {
    case shell, claude, codex

    /// The command a new tab of this kind starts with (nil = the login shell).
    var command: String? {
        switch self {
        case .shell: nil
        case .claude: "claude"
        case .codex: "codex"
        }
    }

    /// The tab's name for a folder or project: "taki", "Claude: taki", "Codex: taki".
    func title(for name: String) -> String {
        switch self {
        case .shell: name
        case .claude: "Claude: \(name)"
        case .codex: "Codex: \(name)"
        }
    }

    init(command: String?) {
        if command?.hasPrefix("claude") == true { self = .claude }
        else if command?.hasPrefix("codex") == true { self = .codex }
        else { self = .shell }
    }
}

/// One in-app terminal tab. Saved across launches (folder, title, what it runs).
struct TerminalTab: Identifiable, Equatable, Codable {
    var id = UUID()
    var title: String
    var folder: String
    var command: String?        // nil = login shell; "claude ..." = Claude Code; "codex" = Codex
    var renamed = false         // the owner named it: keep the name instead of following the folder
    var sessionID: String?      // the Claude Code session seen running in it, to resume after a relaunch

    var kind: TabKind { TabKind(command: command) }
    var isClaude: Bool { kind == .claude }
    var isCodex: Bool { kind == .codex }

    init(title: String, folder: String, command: String?) {
        self.title = title
        self.folder = folder
        self.command = command
    }

    private enum CodingKeys: String, CodingKey { case id, title, folder, command, renamed, sessionID }

    /// Every field but the title and folder is optional, so a file from an older or newer Taki
    /// still restores its tabs instead of dropping all of them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        folder = try c.decode(String.self, forKey: .folder)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        renamed = try c.decodeIfPresent(Bool.self, forKey: .renamed) ?? false
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
    }
}

/// Saves the open terminal tabs. On the next launch shells reopen in the same folder and Claude
/// tabs pick up their own session (`claude --resume <id>`), or their folder's latest one.
enum TerminalStore {
    static var url: URL { AppFiles.folder.appending(path: "terminals.json") }

    static func load() -> [TerminalTab] {
        guard let d = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([TerminalTab].self, from: d) else { return [] }
        return restore(saved)
    }

    /// The command each restored tab runs comes only from its kind, never from the file. A folder
    /// that is gone opens in the home folder. Each Claude session is resumed in one tab only, and
    /// `--continue` (the folder's latest session) is used once per folder, by a tab with no session.
    static func restore(_ saved: [TerminalTab]) -> [TerminalTab] {
        var resumedSessions = Set<String>()
        var claimedFolders = Set(saved.filter { $0.isClaude && $0.sessionID.map { AgentScanner.isSessionID($0) } == true }.map(\.folder))
        return saved.map { t in
            var t = t
            t.id = UUID()                                    // a fresh shell, so a fresh identity
            if !isDirectory(t.folder) { t.folder = NSHomeDirectory() }
            switch t.kind {
            case .shell:
                t.command = nil
                t.sessionID = nil
            case .codex:
                t.command = "codex"
                t.sessionID = nil
            case .claude:
                if let sid = t.sessionID, AgentScanner.isSessionID(sid), resumedSessions.insert(sid).inserted {
                    t.command = "claude --resume \(sid)"
                } else if claimedFolders.insert(t.folder).inserted {
                    t.command = "claude --continue"
                    t.sessionID = nil
                } else {
                    t.command = "claude"
                    t.sessionID = nil
                }
            }
            return t
        }
    }

    /// Written privately (0600): the file names folders and session ids.
    static func save(_ tabs: [TerminalTab]) {
        guard let d = try? JSONEncoder().encode(tabs) else { return }
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }
}
