import XCTest
@testable import Taki

/// A Taki started from inside a Claude Code session must not pass that session's markers on to
/// its tabs (Claude would stop saving transcripts), while the owner's real variables stay.
final class ShellEnvironmentTests: XCTestCase {
    func testClaudeSessionMarkersAreDropped() {
        for key in ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_MESSAGING_TOKEN",
                    "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_PID", "CLAUDE_EFFORT", "AI_AGENT"] {
            XCTAssertTrue(ShellEnvironment.isInheritedAgentMarker(key), key)
        }
    }

    func testOwnersSettingsStay() {
        for key in ["PATH", "HOME", "SHELL", "TERM", "ANTHROPIC_API_KEY", "CLAUDE_CONFIG_DIR", "LANG",
                    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_OAUTH_TOKEN"] {
            XCTAssertFalse(ShellEnvironment.isInheritedAgentMarker(key), key)
        }
    }

    func testOnlyClaudesNoOpGitEditorIsDropped() {
        XCTAssertTrue(ShellEnvironment.isInheritedAgentMarker("GIT_EDITOR", value: "true"))
        XCTAssertFalse(ShellEnvironment.isInheritedAgentMarker("GIT_EDITOR", value: "nvim"))
    }

    func testDropRemovesMarkersFromTheProcessEnvironment() {
        addTeardownBlock {
            unsetenv("CLAUDE_CODE_CHILD_SESSION")
            unsetenv("TAKI_TEST_KEEP")
        }
        setenv("CLAUDE_CODE_CHILD_SESSION", "1", 1)
        setenv("TAKI_TEST_KEEP", "1", 1)
        ShellEnvironment.dropInheritedAgentMarkers()
        let env = ProcessInfo.processInfo.environment
        XCTAssertNil(env["CLAUDE_CODE_CHILD_SESSION"])
        XCTAssertEqual(env["TAKI_TEST_KEEP"], "1")
    }
}
