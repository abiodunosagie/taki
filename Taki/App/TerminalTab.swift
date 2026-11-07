import Foundation

/// The other coding-agent CLIs a tab can start. Each runs its own binary with no arguments;
/// the menus offer only the ones installed on this Mac.
enum AgentCLI: String, CaseIterable {
    case gemini, opencode, qwen, amp, crush, copilot, droid, cursorAgent = "cursor-agent", goose, aider

    var binary: String { rawValue }

    var name: String {
        switch self {
        case .gemini: "Gemini CLI"
        case .opencode: "opencode"
        case .qwen: "Qwen Code"
        case .amp: "Amp"
        case .crush: "Crush"
        case .copilot: "Copilot CLI"
        case .droid: "Factory Droid"
        case .cursorAgent: "Cursor Agent"
        case .goose: "Goose"
        case .aider: "Aider"
        }
    }

    /// Short name for tab titles: "Gemini: taki".
    var shortName: String {
        switch self {
        case .gemini: "Gemini"
        case .qwen: "Qwen"
        case .copilot: "Copilot"
        case .droid: "Droid"
        case .cursorAgent: "Cursor"
        default: name
        }
    }

    /// The installed ones, read from the login PATH and remembered for a minute so menus stay fast
    /// and an agent installed while Taki runs still shows up.
    static func installed(now: Date = Date()) -> [AgentCLI] {
        if let c = cache.get(), now.timeIntervalSince(c.at) < 60 { return c.list }
        let list = allCases.filter { ShellEnvironment.which($0.binary) != nil }
        cache.set((list, now))
        return list
    }

    private static let cache = LockedValue<(list: [AgentCLI], at: Date)?>(nil)
}

/// What a terminal tab runs. The command line for each kind is fixed here, so nothing else (a
/// saved file, a title) ever decides what a tab executes.
enum TabKind: Equatable, Hashable {
    case shell, claude, codex
    case agent(AgentCLI)

    /// The command a new tab of this kind starts with (nil = the login shell).
    var command: String? {
        switch self {
        case .shell: nil
        case .claude: "claude"
        case .codex: "codex"
        case let .agent(a): a.binary
        }
    }

    /// What menus call it: "Shell", "Claude Code", "Codex", "Gemini CLI".
    var menuName: String {
        switch self {
        case .shell: "Shell"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case let .agent(a): a.name
        }
    }

    /// The tab's name for a folder or project: "taki", "Claude: taki", "Codex: taki".
    func title(for name: String) -> String {
        switch self {
        case .shell: name
        case .claude: "Claude: \(name)"
        case .codex: "Codex: \(name)"
        case let .agent(a): "\(a.shortName): \(name)"
        }
    }

    /// Every kind a new-tab menu offers: shell, Claude Code, Codex, then installed agent CLIs.
    static var menuKinds: [TabKind] { [.shell, .claude, .codex] + AgentCLI.installed().map { .agent($0) } }

    init(command: String?) {
        // The leading program name only ("claude; rm -rf ~" is still a Claude tab, and the command
        // it runs is rebuilt from the kind, never taken from the saved text).
        let word = String((command ?? "").prefix { $0.isLetter || $0.isNumber || $0 == "-" })
        if word == "claude" { self = .claude }
        else if word == "codex" { self = .codex }
        else if let a = AgentCLI(rawValue: word) { self = .agent(a) }
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
            case .codex, .agent:
                t.command = t.kind.command
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
