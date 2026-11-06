import Foundation

/// One parsed line of Claude Code's `--output-format stream-json` output.
/// Shapes verified against Claude Code 2.1.319 on 2026-11-06 (init, assistant, user tool_result,
/// stream_event deltas, control_request can_use_tool, rate_limit_event, result).
enum ClaudeEvent: Equatable {
    case initialized(sessionID: String, model: String, cwd: String)
    case textDelta(String)
    case assistantText(messageID: String, text: String)
    case toolUse(id: String, name: String, summary: String)
    case toolResult(toolUseID: String, text: String, isError: Bool)
    case permissionRequest(PermissionRequest)
    case rateLimits(RateLimits)
    case turnFinished(TurnResult)
    case other
}

struct PermissionRequest: Equatable, Identifiable {
    let id: String            // control request id, echoed in the response
    let toolName: String
    let summary: String
    let inputJSON: Data       // the tool input, sent back unchanged on allow
}

struct RateLimits: Equatable, Codable {
    var fiveHourUsed: Double?     // 0...1
    var fiveHourResets: Date?
    var weekUsed: Double?
    var weekResets: Date?
}

struct TurnResult: Equatable {
    let isError: Bool
    let costUSD: Double
    let inputTokens: Int
    let outputTokens: Int
    let text: String
}

enum ClaudeStreamParser {
    static func parse(line: Data) -> ClaudeEvent {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String else { return .other }
        switch type {
        case "system":
            if obj["subtype"] as? String == "init" {
                return .initialized(sessionID: obj["session_id"] as? String ?? "",
                                    model: obj["model"] as? String ?? "",
                                    cwd: obj["cwd"] as? String ?? "")
            }
        case "stream_event":
            if let ev = obj["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
               let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                return .textDelta(text)
            }
        case "assistant":
            guard let msg = obj["message"] as? [String: Any],
                  let blocks = msg["content"] as? [[String: Any]] else { break }
            let mid = msg["id"] as? String ?? ""
            for b in blocks {
                switch b["type"] as? String {
                case "text":
                    return .assistantText(messageID: mid, text: b["text"] as? String ?? "")
                case "tool_use":
                    let input = b["input"] as? [String: Any] ?? [:]
                    return .toolUse(id: b["id"] as? String ?? "", name: b["name"] as? String ?? "tool",
                                    summary: summarize(tool: b["name"] as? String ?? "", input: input))
                default: continue
                }
            }
        case "user":
            guard let msg = obj["message"] as? [String: Any],
                  let blocks = msg["content"] as? [[String: Any]] else { break }
            for b in blocks where b["type"] as? String == "tool_result" {
                return .toolResult(toolUseID: b["tool_use_id"] as? String ?? "",
                                   text: flatten(b["content"]), isError: b["is_error"] as? Bool ?? false)
            }
        case "control_request":
            guard let req = obj["request"] as? [String: Any], req["subtype"] as? String == "can_use_tool"
            else { break }
            let input = req["input"] as? [String: Any] ?? [:]
            let name = req["tool_name"] as? String ?? "tool"
            let data = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
            return .permissionRequest(PermissionRequest(
                id: obj["request_id"] as? String ?? UUID().uuidString, toolName: name,
                summary: (req["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? summarize(tool: name, input: input),
                inputJSON: data))
        case "rate_limit_event":
            guard let info = obj["rate_limit_info"] as? [String: Any],
                  let windows = info["unifiedWindows"] as? [String: Any] else { break }
            func window(_ key: String) -> (Double?, Date?) {
                let w = windows[key] as? [String: Any]
                let used = w?["utilization"] as? Double
                let reset = (w?["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
                return (used, reset)
            }
            let five = window("five_hour"), week = window("seven_day")
            return .rateLimits(RateLimits(fiveHourUsed: five.0, fiveHourResets: five.1,
                                          weekUsed: week.0, weekResets: week.1))
        case "result":
            let usage = obj["usage"] as? [String: Any] ?? [:]
            let input = (usage["input_tokens"] as? Int ?? 0) + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                + (usage["cache_read_input_tokens"] as? Int ?? 0)
            return .turnFinished(TurnResult(isError: obj["is_error"] as? Bool ?? false,
                                            costUSD: obj["total_cost_usd"] as? Double ?? 0,
                                            inputTokens: input, outputTokens: usage["output_tokens"] as? Int ?? 0,
                                            text: obj["result"] as? String ?? ""))
        default: break
        }
        return .other
    }

    static func flatten(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    /// A one-line, human description of a tool call for the chat and the permission sheet.
    static func summarize(tool: String, input: [String: Any]) -> String {
        if let cmd = input["command"] as? String { return cmd }
        if let path = input["file_path"] as? String { return (path as NSString).abbreviatingWithTildeInPath }
        if let pattern = input["pattern"] as? String { return pattern }
        if let url = input["url"] as? String { return url }
        if let q = input["query"] as? String { return q }
        if let d = input["description"] as? String { return d }
        return tool
    }

    // MARK: lines the app writes to Claude's stdin

    static func initializeRequest(id: String) -> Data {
        encode(["type": "control_request", "request_id": id, "request": ["subtype": "initialize"]])
    }

    static func userMessage(_ text: String) -> Data {
        encode(["type": "user", "message": ["role": "user", "content": text]])
    }

    static func permissionResponse(_ req: PermissionRequest, allow: Bool, denyReason: String = "") -> Data {
        let input = (try? JSONSerialization.jsonObject(with: req.inputJSON)) ?? [String: Any]()
        let decision: [String: Any] = allow
            ? ["behavior": "allow", "updatedInput": input]
            : ["behavior": "deny", "message": denyReason.isEmpty ? "The user declined this in Taki." : denyReason]
        return encode(["type": "control_response",
                       "response": ["subtype": "success", "request_id": req.id, "response": decision]])
    }

    static func interruptRequest(id: String) -> Data {
        encode(["type": "control_request", "request_id": id, "request": ["subtype": "interrupt"]])
    }

    private static func encode(_ obj: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        data.append(0x0A)
        return data
    }
}
