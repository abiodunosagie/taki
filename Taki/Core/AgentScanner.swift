import Foundation

/// A coding-agent session running anywhere on this Mac (terminal, IDE, or a Taki chat).
struct LiveAgent: Identifiable, Equatable, Sendable {
    enum Tool: String, Sendable { case claude = "Claude Code", codex = "Codex", cursor = "Cursor" }
    enum Status: String, Sendable { case working, idle, waiting }
    let id: String               // session id
    let pid: Int32
    let tool: Tool
    let cwd: String
    let name: String
    let status: Status
    let startedAt: Date
    let statusSince: Date
    var task: String             // first prompt of the session, the human label
    var contextTokens: Int
    var hostApp: String? = nil
    var serverCount = 0
    var project: String? = nil      // the repository the session is working in (from what it touches)

    var folderName: String { (cwd as NSString).lastPathComponent }

    enum SubtitleStyle { case full, compact, tree }

    /// "Claude Code · working 42m" (compact), plus the host app, servers and folder (full), or the
    /// menu bar tree line "In Terminal · Idle 2m · 7 servers" (tree).
    func subtitle(style: SubtitleStyle) -> String {
        let since = Format.elapsed(since: statusSince)
        let state = status == .waiting ? "waiting for you" : "\(status.rawValue) \(since)"
        var parts: [String] = []
        switch style {
        case .compact:
            parts = [tool.rawValue, state]
        case .full:
            parts = [tool.rawValue]
            if let hostApp { parts.append("in \(hostApp)") }
            parts.append(state)
            if serverCount > 0 { parts.append(Format.plural(serverCount, "server")) }
            parts.append(folderName)
        case .tree:
            if let hostApp { parts.append("In \(hostApp)") }
            parts.append(state.prefix(1).uppercased() + state.dropFirst())
            if serverCount > 0 { parts.append(Format.plural(serverCount, "server")) }
        }
        return parts.joined(separator: " · ")
    }
}

/// Reads live sessions. Claude Code writes `~/.claude/sessions/<pid>.json` for every running
/// session (verified on 2.1.319: pid, sessionId, cwd, name, status busy/idle, startedAt,
/// statusUpdatedAt). The transcript `~/.claude/projects/<slug>/<sessionId>.jsonl` gives the task
/// title and the latest context size.
enum AgentScanner {
    static let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")

    static func scan() -> [LiveAgent] {
        let dir = claudeDir.appending(path: "sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [LiveAgent] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = o["pid"] as? Int, isAlive(Int32(pid)),
                  let sid = o["sessionId"] as? String, isSessionID(sid), isClaudeProcess(Int32(pid)) else { continue }
            let cwd = o["cwd"] as? String ?? ""
            let raw = o["status"] as? String ?? "idle"
            let status: LiveAgent.Status = raw == "busy" ? .working : (raw == "waiting" ? .waiting : .idle)
            let started = Date(timeIntervalSince1970: (o["startedAt"] as? Double ?? 0) / 1000)
            let rawSince = o["statusUpdatedAt"] as? Double ?? 0
            let since = rawSince > 0 ? Date(timeIntervalSince1970: rawSince / 1000) : started
            let info = autoreleasepool { transcriptInfo(sessionID: sid, cwd: cwd) }
            out.append(LiveAgent(id: sid, pid: Int32(pid), tool: .claude, cwd: cwd,
                                 name: o["name"] as? String ?? (cwd as NSString).lastPathComponent,
                                 status: status, startedAt: started, statusSince: since,
                                 task: info.task ?? (o["name"] as? String ?? "Claude session"),
                                 contextTokens: info.context,
                                 project: info.project ?? ProjectRoot.of(cwd)))
        }
        return out.sorted { a, b in
            if (a.status == .waiting) != (b.status == .waiting) { return a.status == .waiting }
            return a.startedAt > b.startedAt
        }
    }

    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// Codex and Cursor's terminal agent leave no session registry, so they are found by process:
    /// a `codex` or `cursor-agent` program owned by this user. Busy means it used CPU in the last
    /// second (ps %cpu), which is when it is thinking or running a tool.
    static func otherAgents() -> [LiveAgent] {
        guard let d = ShellEnvironment.run("/bin/ps", ["-axo", "pid=,uid=,%cpu=,etime=,comm="]),
              let text = String(data: d, encoding: .utf8) else { return [] }
        var out: [LiveAgent] = []
        for line in text.split(separator: "\n") {
            let p = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard p.count == 5, let pid = Int32(p[0]), UInt32(p[1]) == getuid(), let cpu = Double(p[2]) else { continue }
            let name = (String(p[4]) as NSString).lastPathComponent
            let tool: LiveAgent.Tool
            switch name {
            case "codex": tool = .codex
            case "cursor-agent": tool = .cursor
            default: continue
            }
            let cwd = ProcessScanner.cwd(of: pid)
            let started = ProcessScanner.startTime(of: pid) ?? Date()
            out.append(LiveAgent(id: "\(tool.rawValue)-\(pid)", pid: pid, tool: tool, cwd: cwd,
                                 name: (cwd as NSString).lastPathComponent, status: cpu > 2 ? .working : .idle,
                                 startedAt: started, statusSince: started,
                                 task: "\(tool.rawValue) in \((cwd as NSString).lastPathComponent)", contextTokens: 0,
                                 project: ProjectRoot.of(cwd)))
        }
        return out
    }

    /// Session ids are UUIDs. Anything else (a hand-edited or planted file) is ignored, because the
    /// id ends up in a file path and in a `claude --resume <id>` terminal command.
    static func isSessionID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    /// The pid still belongs to Claude Code (a stale session file can name a reused pid).
    static func isClaudeProcess(_ pid: Int32) -> Bool {
        let path = ProcessScanner.path(of: pid).lowercased()
        return path.contains("claude") || path.hasSuffix("/node")
    }

    /// Folders a tool call points at: file paths, and `cd X` / `git -C X` in shell commands.
    static func paths(in input: [String: Any]) -> [String] {
        var out: [String] = []
        for key in ["file_path", "path", "notebook_path"] {
            if let p = input[key] as? String, p.hasPrefix("/") || p.hasPrefix("~") { out.append(expand(p)) }
        }
        if let cmd = input["command"] as? String {
            let words = cmd.split(whereSeparator: { $0 == " " || $0 == ";" || $0 == "&" }).map(String.init)
            for (i, w) in words.enumerated() where (w == "cd" || w == "-C") && i + 1 < words.count {
                let target = words[i + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if target.hasPrefix("/") || target.hasPrefix("~") { out.append(expand(target)) }
            }
        }
        return out
    }

    static func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

    /// Claude Code's project folder slug: every non-alphanumeric character becomes "-".
    static func slug(for cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func transcriptURL(sessionID: String, cwd: String) -> URL {
        claudeDir.appending(path: "projects").appending(path: slug(for: cwd)).appending(path: "\(sessionID).jsonl")
    }

    /// How many recent tool paths vote on the project of a session started outside a repository.
    static let votedPaths = 40
    private static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

    /// First real user prompt (the task) from the head of the file, latest context size from its tail.
    static func transcriptInfo(sessionID: String, cwd: String) -> (task: String?, context: Int, project: String?) {
        let url = transcriptURL(sessionID: sessionID, cwd: cwd)
        guard let h = try? FileHandle(forReadingFrom: url) else { return (nil, 0, nil) }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 256_000)) ?? Data()
        var task: String?
        for line in head.split(separator: 0x0A) {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  o["type"] as? String == "user", o["isMeta"] as? Bool != true,
                  let msg = o["message"] as? [String: Any] else { continue }
            let text = (msg["content"] as? String) ?? ClaudeStreamParser.flatten(msg["content"])
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty || clean.hasPrefix("<") { continue }
            task = String(clean.split(separator: "\n").first ?? "").prefix(80).description
            break
        }
        var context = 0
        var aiTitle: String?
        // The repository it was started in is its project. Only a session started outside any
        // repository (from the home folder, say) is placed by the paths its recent tools touched.
        let cwdRoot = ProjectRoot.of(cwd)
        var projectVotes: [String: Int] = [:]
        var touched = cwdRoot == nil ? 0 : Self.votedPaths
        if let size = try? h.seekToEnd(), size > 0 {
            let start = size > 400_000 ? size - 400_000 : 0
            try? h.seek(toOffset: start)
            let tail = (try? h.readToEnd()) ?? Data()
            for line in tail.split(separator: 0x0A).reversed() {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                // Claude Code writes its own short session title as {"type":"ai-title","aiTitle":...}.
                if aiTitle == nil, o["type"] as? String == "ai-title", let t = o["aiTitle"] as? String, !t.isEmpty {
                    aiTitle = t
                }
                if context == 0, let msg = o["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] {
                    context = (u["input_tokens"] as? Int ?? 0) + (u["cache_creation_input_tokens"] as? Int ?? 0)
                        + (u["cache_read_input_tokens"] as? Int ?? 0) + (u["output_tokens"] as? Int ?? 0)
                }
                // The paths its recent tools touched (newest first) say which repository it works in.
                if touched < Self.votedPaths, let msg = o["message"] as? [String: Any],
                   let blocks = msg["content"] as? [[String: Any]] {
                    for b in blocks where b["type"] as? String == "tool_use" {
                        for path in paths(in: b["input"] as? [String: Any] ?? [:]) where path.hasPrefix(home + "/") {
                            if let root = ProjectRoot.of(path) {
                                projectVotes[root, default: 0] += max(1, Self.votedPaths - touched)   // newer counts more
                            }
                            touched += 1
                        }
                    }
                }
                if aiTitle != nil && context > 0 && touched >= Self.votedPaths { break }
            }
        }
        let project = cwdRoot ?? projectVotes.max { $0.value < $1.value }?.key
        return (aiTitle ?? task, context, project)
    }
}
