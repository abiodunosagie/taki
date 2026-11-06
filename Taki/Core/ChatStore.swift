import Foundation

/// Remembers open chats across relaunches (folder, title, Claude session id). The conversation
/// itself is Claude Code's own transcript, read back for display and resumed with `--resume`.
enum ChatStore {
    struct Saved: Codable, Equatable {
        let folder: String
        let title: String
        let sessionID: String
    }

    static var url: URL { WorkspaceStore.url.deletingLastPathComponent().appending(path: "chats.json") }

    static func load() -> [Saved] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return ((try? JSONDecoder().decode([Saved].self, from: d)) ?? []).filter { AgentScanner.isSessionID($0.sessionID) }
    }

    static func save(_ list: [Saved]) {
        if let d = try? JSONEncoder().encode(list) {
            try? d.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// User prompts, assistant text and tool calls from a transcript, oldest first, last 200.
    @MainActor
    static func history(sessionID: String, folder: String) -> [ChatSession.Message] {
        let url = AgentScanner.transcriptURL(sessionID: sessionID, cwd: folder)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        var out: [ChatSession.Message] = []
        for line in data.split(separator: 0x0A) {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true,
                  let msg = o["message"] as? [String: Any] else { continue }
            switch o["type"] as? String {
            case "user":
                if let text = msg["content"] as? String, !text.hasPrefix("<") {
                    out.append(.init(role: .user, text: text))
                }
            case "assistant":
                for b in msg["content"] as? [[String: Any]] ?? [] {
                    if b["type"] as? String == "text", let t = b["text"] as? String, !t.isEmpty {
                        out.append(.init(role: .assistant, text: t))
                    } else if b["type"] as? String == "tool_use" {
                        let name = b["name"] as? String ?? "tool"
                        out.append(.init(role: .tool, text: name,
                                         detail: ClaudeStreamParser.summarize(tool: name, input: b["input"] as? [String: Any] ?? [:])))
                    }
                }
            default: continue
            }
        }
        return Array(out.suffix(200))
    }
}
