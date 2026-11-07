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
        let restored = TerminalStore.restore([tab])
        XCTAssertEqual(restored.first?.command, "gemini")           // rebuilt from the kind: the tail never runs
        XCTAssertNil(restored.first?.sessionID)
    }
}
