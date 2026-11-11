import XCTest
@testable import Taki

/// The "Recent projects" list in the terminal + menu: which folders it offers and in what order.
@MainActor
final class TerminalMenuTests: XCTestCase {
    /// Stands in for ProjectRoot.of: anything under /p/<name> belongs to the project /p/<name>.
    let root: (String) -> String? = { path in
        let parts = path.split(separator: "/")
        return parts.count >= 2 && parts[0] == "p" ? "/p/\(parts[1])" : nil
    }

    func folders(tabs: [String] = [], agents: [String] = [], excluding: Set<String> = [], limit: Int = 6) -> [String] {
        AppModel.recentFolders(tabFolders: tabs, agentFolders: agents, excluding: excluding,
                               home: "/Users/me", limit: limit, root: root)
    }

    func testTabsComeBeforeAgentsAndEachProjectOnce() {
        XCTAssertEqual(folders(tabs: ["/p/a/src", "/p/b"], agents: ["/p/a", "/p/c/lib"]), ["/p/a", "/p/b", "/p/c"])
    }

    func testCurrentFolderAndWorkspacesAreLeftOut() {
        // The current tab sits deep inside /p/a, so all of /p/a is already "In a" at the top.
        XCTAssertEqual(folders(tabs: ["/p/a", "/p/b"], agents: ["/p/c"], excluding: ["/p/a/src", "/p/c"]), ["/p/b"])
    }

    func testHomeAndEmptyFoldersAreNeverOffered() {
        XCTAssertEqual(folders(tabs: ["/Users/me", ""], agents: ["/tmp/x"]), ["/tmp/x"])
    }

    func testListStopsAtTheLimit() {
        XCTAssertEqual(folders(tabs: ["/p/a", "/p/b", "/p/c"], limit: 2), ["/p/a", "/p/b"])
    }

    // MARK: tab kinds

    func testCommandsMapBackToTheirKind() {
        XCTAssertEqual(TabKind(command: nil), .shell)
        XCTAssertEqual(TabKind(command: "claude --resume abc"), .claude)
        XCTAssertEqual(TabKind(command: "codex"), .codex)
        XCTAssertEqual(TabKind(command: "gemini"), .agent(.gemini))
        XCTAssertEqual(TabKind(command: "cursor-agent"), .agent(.cursorAgent))
        XCTAssertEqual(TabKind(command: "claudette"), .shell)     // a prefix is not a match
        XCTAssertEqual(TabKind(command: "rm -rf /"), .shell)       // unknown commands never become a kind
    }

    func testEveryKindRoundTripsThroughItsCommand() {
        for kind in [TabKind.shell, .claude, .codex] + AgentCLI.allCases.map({ .agent($0) }) {
            XCTAssertEqual(TabKind(command: kind.command), kind)
        }
    }

    func testTitles() {
        XCTAssertEqual(TabKind.agent(.gemini).title(for: "taki"), "Gemini: taki")
        XCTAssertEqual(TabKind.agent(.opencode).title(for: "taki"), "opencode: taki")
        XCTAssertEqual(TabKind.claude.title(for: "taki"), "Claude: taki")
    }

    func testRestoredAgentTabRunsOnlyItsOwnBinary() {
        var tab = TerminalTab(title: "Gemini: x", folder: NSTemporaryDirectory(), command: "gemini; curl evil")
        tab.sessionID = "s"
        let restored = TerminalStore.restore([tab], codexLatest: { _ in nil })
        XCTAssertEqual(restored.first?.command, "gemini --resume latest")   // rebuilt from the kind: the tail never runs
        XCTAssertNil(restored.first?.sessionID)
    }

    /// After a relaunch each agent tab picks up its folder's latest session, once per folder.
    func testAgentTabsResumeTheirLatestSession() {
        let id = "01a09f56-1c0a-7490-b7db-0e3e0ad78426"
        func tab(_ cmd: String, _ folder: String) -> TerminalTab { TerminalTab(title: "t", folder: folder, command: cmd) }
        let out = TerminalStore.restore([
            tab("codex", "/tmp"), tab("codex", "/tmp"), tab("codex", "/"),
            tab("opencode", "/tmp"), tab("opencode", "/tmp"), tab("aider", "/tmp"),
        ], codexLatest: { $0 == "/tmp" ? id : nil })
        XCTAssertEqual(out.map(\.command), [
            "codex resume \(id)", "codex", "codex",                    // second tab fresh; "/" has no session
            "opencode --continue", "opencode", "aider",                 // aider has no verified flag
        ])
        XCTAssertTrue(out.allSatisfy { $0.kind != .shell })
    }

    func testCodexSessionMetaIsReadSafely() throws {
        let good = #"{"type":"session_meta","payload":{"id":"01A09F56-1C0A-7490-B7DB-0E3E0AD78426","cwd":"/tmp/x/"}}"#
        XCTAssertEqual(CodexSessions.parse(Data(good.utf8)), .init(id: "01a09f56-1c0a-7490-b7db-0e3e0ad78426", cwd: "/tmp/x"))
        for bad in [#"{"type":"turn","payload":{"id":"01a09f56-1c0a-7490-b7db-0e3e0ad78426","cwd":"/tmp"}}"#,
                    #"{"type":"session_meta","payload":{"id":"x; rm -rf ~","cwd":"/tmp"}}"#,
                    #"{"type":"session_meta","payload":{"cwd":"/tmp"}}"#, "not json"] {
            XCTAssertNil(CodexSessions.parse(Data(bad.utf8)), bad)
        }
        // Newest file wins, and only one whose folder matches.
        let root = FileManager.default.temporaryDirectory.appending(path: "codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ day: String, _ name: String, _ id: String, _ cwd: String) throws {
            let dir = root.appending(path: day)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Real first lines carry Codex's whole system prompt (about 18 KB): make them bigger than one read.
            let prompt = String(repeating: "x", count: 90_000)
            let line = #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","base_instructions":"\#(prompt)"}}"# + "\n{}"
            try Data(line.utf8).write(to: dir.appending(path: name))
        }
        let old = UUID().uuidString.lowercased(), new = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        // A real folder under /var (a symlink to /private/var): Codex records the /private form.
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let recorded = project.resolvingSymlinksInPath().path.hasPrefix("/private") ? project.path : "/private" + project.path
        try write("2026/09/01", "rollout-2026-09-01T10-00-00-a.jsonl", old, recorded)
        try write("2026/11/01", "rollout-2026-11-01T10-00-00-b.jsonl", new, recorded)
        try write("2026/11/02", "rollout-2026-11-02T10-00-00-c.jsonl", other, "/tmp/q")
        XCTAssertEqual(CodexSessions.latest(in: project.path, root: root), new)
        XCTAssertEqual(CodexSessions.latest(in: recorded, root: root), new)
        XCTAssertNil(CodexSessions.latest(in: "/tmp/none", root: root))
    }
}
