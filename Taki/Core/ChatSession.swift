import Foundation
import Observation

/// One chat with Claude Code, run headless (`claude -p` with stream-json in and out) so Taki
/// shows the conversation and answers permission prompts in its own UI.
@MainActor
@Observable
final class ChatSession: Identifiable {
    enum State: Equatable { case starting, idle, working, waiting, ended(String) }

    struct Message: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant, tool, error }
        let id = UUID()
        var role: Role
        var text: String
        var detail: String = ""
        var isError = false
        var toolUseID: String? = nil
    }

    let id = UUID()
    let folder: URL
    var title: String
    private(set) var state: State = .starting
    private(set) var messages: [Message] = []
    private(set) var pending: [PermissionRequest] = []
    private(set) var sessionID: String?
    private(set) var model = ""
    private(set) var totalCostUSD = 0.0
    private(set) var contextTokens = 0
    private(set) var startedAt = Date()
    private(set) var lastActivity = Date()
    var modelChoice: String
    var permissionMode: String

    /// Share of the context window in use. Claude models run 200K, or 1M when the long-context
    /// option is on; a session already past 200K is on the 1M window.
    static func contextShare(_ tokens: Int) -> Double {
        let window = tokens > 200_000 ? 1_000_000.0 : 200_000.0
        return min(1, Double(tokens) / window)
    }

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stdin: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var streamingIndex: Int?
    @ObservationIgnored private var sawReply = false     // anything Taki understood came back this turn
    @ObservationIgnored private var interrupted = false  // the owner pressed Stop this turn
    /// Bumped for every new Claude process, so output or an exit from an older one is ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored var onRateLimits: ((RateLimits) -> Void)?
    @ObservationIgnored var onChange: (() -> Void)?     // session id or title changed: persist

    init(folder: URL, title: String, resumeID: String? = nil, model: String = "", permissionMode: String = "") {
        self.folder = folder
        self.title = title
        self.sessionID = resumeID
        self.modelChoice = model
        self.permissionMode = permissionMode
    }

    var contextShare: Double { Self.contextShare(contextTokens) }

    /// A chat restored after a relaunch: shows its history and resumes the session on the next send.
    func restore(history: [Message]) {
        messages = history
        state = .idle
    }

    func start() {
        guard process == nil else { return }
        guard !Demo.isOn else { state = .idle; return }     // a sample chat starts no Claude process
        guard let claude = ShellEnvironment.which("claude") else {
            state = .ended("Claude Code was not found on your PATH. Install it, then reopen this chat.")
            return
        }
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-prompt-tool", "stdio"]
        if let sessionID { args += ["--resume", sessionID] }
        if !modelChoice.isEmpty { args += ["--model", modelChoice] }
        if !permissionMode.isEmpty { args += ["--permission-mode", permissionMode] }   // "" = the owner's Claude Code setting

        generation += 1
        let gen = generation
        buffer = Data()
        streamingIndex = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = args
        p.currentDirectoryURL = folder
        p.environment = ShellEnvironment.load()
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }          // EOF: stop, or it fires forever
            Task { @MainActor in self?.consume(chunk, generation: gen) }
        }
        let errTail = LockedValue(Data())
        errPipe.fileHandleForReading.readabilityHandler = { h in             // drained live so it never blocks
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            errTail.set((errTail.get() + chunk).suffix(4_000))
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let rest = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()   // the last lines of the turn
            let err = String(decoding: errTail.get(), as: UTF8.self)
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            Task { @MainActor in
                self?.consume(rest, generation: gen)
                self?.finished(code: code, stderr: err, generation: gen)
            }
        }
        do {
            try p.run()
        } catch {
            state = .ended("Could not start Claude Code: \(error.localizedDescription)")
            return
        }
        process = p
        stdin = inPipe.fileHandleForWriting
        write(ClaudeStreamParser.initializeRequest(id: "taki-init"))
        state = .idle
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if process == nil { start() }
        if case .ended = state { return }                                    // could not start: keep the reason on screen
        messages.append(Message(role: .user, text: trimmed))
        if messages.count == 1 || title.hasPrefix("New chat") { title = String(trimmed.prefix(48)) }
        state = .working
        sawReply = false
        interrupted = false
        lastActivity = Date()
        write(ClaudeStreamParser.userMessage(trimmed))   // last: a failed write leaves the chat ended, not working
    }

    func answer(_ req: PermissionRequest, allow: Bool) {
        write(ClaudeStreamParser.permissionResponse(req, allow: allow))
        pending.removeAll { $0.id == req.id }
        if pending.isEmpty { state = .working }
    }

    func interrupt() {
        interrupted = true
        write(ClaudeStreamParser.interruptRequest(id: "taki-int-\(UUID().uuidString.prefix(8))"))
    }

    /// Ends the Claude process now. Its exit arrives later and is ignored (an older generation),
    /// so a message sent right after this starts a fresh process instead of writing to a closed pipe.
    func stop() {
        try? stdin?.close()
        process?.terminate()
        process = nil
        stdin = nil
        buffer = Data()
        streamingIndex = nil
        pending.removeAll()
        if state == .working || state == .waiting || state == .starting { state = .idle }
    }

    /// An idle chat gives its Claude process back after a while; the next message resumes the
    /// same session with --resume, so nothing is lost.
    static let idleLimit: TimeInterval = 600

    /// Only a chat that has a conversation on disk can be resumed later, so one with no message
    /// sent yet keeps its process.
    var isSuspendable: Bool { process != nil && state == .idle && pending.isEmpty && sessionID != nil
        && messages.contains { $0.role == .user } && Date().timeIntervalSince(lastActivity) > Self.idleLimit }

    func suspend() { stop() }

    // MARK: stream

    private func write(_ data: Data) {
        guard let stdin else { return }
        do { try stdin.write(contentsOf: data) } catch {
            state = .ended("Lost the connection to Claude Code.")
        }
    }

    private func consume(_ chunk: Data, generation gen: Int) {
        guard gen == generation, !chunk.isEmpty else { return }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if !line.isEmpty { apply(ClaudeStreamParser.parse(line: line)) }
        }
    }

    func apply(_ event: ClaudeEvent) {
        lastActivity = Date()
        switch event {
        case .textDelta, .assistantText, .toolUse, .permissionRequest: sawReply = true
        default: break
        }
        switch event {
        case let .initialized(sid, model, _):
            let changed = sessionID != sid
            sessionID = sid
            self.model = model
            if changed { onChange?() }
        case let .textDelta(text):
            if let i = streamingIndex, messages.indices.contains(i) {
                messages[i].text += text
            } else {
                messages.append(Message(role: .assistant, text: text))
                streamingIndex = messages.count - 1
            }
        case let .assistantText(_, text):
            if let i = streamingIndex, messages.indices.contains(i) {
                messages[i].text = text           // the final block replaces the streamed draft
            } else {
                messages.append(Message(role: .assistant, text: text))
            }
            streamingIndex = nil
        case let .toolUse(id, name, summary):
            streamingIndex = nil
            messages.append(Message(role: .tool, text: name, detail: summary, toolUseID: id))
        case let .toolResult(toolID, text, isError):
            if let i = messages.lastIndex(where: { $0.toolUseID == toolID }) {
                messages[i].isError = isError
                if isError { messages[i].detail += "\n" + text.prefix(400) }
            }
        case let .permissionRequest(req):
            pending.append(req)
            state = .waiting
        case let .rateLimits(limits):
            onRateLimits?(limits)
        case let .turnFinished(result):
            streamingIndex = nil
            totalCostUSD += result.costUSD
            contextTokens = result.inputTokens + result.outputTokens
            if result.isError, !result.text.isEmpty {
                messages.append(Message(role: .error, text: result.text))
            } else if !sawReply && !result.text.isEmpty {
                messages.append(Message(role: .assistant, text: result.text))      // the final text is still there
            } else if !sawReply && !interrupted && result.outputTokens > 0 {
                // Claude wrote a reply (it used output tokens) but in a form Taki does not show.
                messages.append(Message(role: .error, text: "Claude replied in a form Taki can't show yet. Use Continue in Claude Code to read it."))
            }
            state = pending.isEmpty ? .idle : .waiting
        case .other:
            break
        }
    }

    private func finished(code: Int32, stderr: String, generation gen: Int) {
        guard gen == generation else { return }                              // an older process Taki already let go
        let midTurn = state == .working || state == .waiting
        process = nil
        stdin = nil
        buffer = Data()
        streamingIndex = nil
        pending.removeAll()
        if code == 0 || code == 15 {                                         // a resumable chat, not a dead one
            if midTurn { messages.append(Message(role: .error, text: "Claude Code stopped before it finished. Send again to pick up where it left off.")) }
            state = .idle
        } else {
            let tail = stderr.split(separator: "\n").suffix(2).joined(separator: " ")
            state = .ended("Claude Code stopped unexpectedly (exit \(code)). \(tail.prefix(160))")
        }
    }
}
