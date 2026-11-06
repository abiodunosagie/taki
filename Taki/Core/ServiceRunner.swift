import Foundation
import Observation

/// One line of service output, for the Logs card.
struct LogLine: Identifiable, Equatable, Sendable {
    let id: Int
    let time: Date
    let service: String
    let text: String
    let isError: Bool
}

/// Runs a workspace's services (`pnpm dev`, ...) through the login shell, with the workspace's
/// Keychain env vars injected, and keeps the last lines of their output.
@MainActor
@Observable
final class ServiceRunner {
    struct Running: Equatable {
        let pid: Int32
        let startedAt: Date
    }

    private(set) var running: [UUID: Running] = [:]       // service id -> process
    private(set) var logs: [UUID: [LogLine]] = [:]        // workspace id -> lines
    @ObservationIgnored private var processes: [UUID: Process] = [:]
    @ObservationIgnored private var counter = 0
    static let maxLines = 2_000

    func isRunning(_ s: Workspace.Service) -> Bool { running[s.id] != nil }

    /// Demo mode only: services shown as running with sample output, no process started.
    func showDemo(running: [UUID: Running], logs: [UUID: [LogLine]]) {
        self.running = running
        self.logs = logs
    }

    func start(_ s: Workspace.Service, in ws: Workspace) {
        guard processes[s.id] == nil, !Demo.isOn else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "exec \(s.command)"]
        p.currentDirectoryURL = ws.folderURL
        var env = ShellEnvironment.load()
        for name in ws.envNames { if let v = Keychain.get(name: name, workspace: ws.id) { env[name] = v } }
        env["FORCE_COLOR"] = "0"
        env["NO_COLOR"] = "1"
        if let port = s.port { env["PORT"] = String(port) }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        for (pipe, isErr) in [(out, false), (err, true)] {
            let carry = LockedValue(Data())     // a chunk can end inside a line or a UTF-8 character
            pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; return }
                var buf = carry.get() + d
                guard let nl = buf.lastIndex(of: 0x0A) else { carry.set(buf.count > 64_000 ? Data() : buf); return }
                let complete = buf[buf.startIndex...nl]
                buf = Data(buf[buf.index(after: nl)...])
                carry.set(buf)
                let text = String(decoding: complete, as: UTF8.self)
                Task { @MainActor in self?.append(text, service: s.name, workspace: ws.id, isErr: isErr) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                // Only clear the slot if it still holds THIS process (a quick restart may have replaced it).
                if self?.processes[s.id] === proc {
                    self?.processes[s.id] = nil
                    self?.running[s.id] = nil
                }
                self?.append("exited with code \(code)", service: s.name, workspace: ws.id, isErr: code != 0 && code != 15)
            }
        }
        do {
            try p.run()
            processes[s.id] = p
            running[s.id] = Running(pid: p.processIdentifier, startedAt: Date())
            append("$ \(s.command)", service: s.name, workspace: ws.id, isErr: false)
        } catch {
            append("could not start: \(error.localizedDescription)", service: s.name, workspace: ws.id, isErr: true)
        }
    }

    func stop(_ s: Workspace.Service) {
        guard let p = processes[s.id] else { return }
        end(p)
        processes[s.id] = nil          // free the slot now so an immediate start works
        running[s.id] = nil
    }

    /// Ends a service and everything it started (pnpm -> node), children first.
    private func end(_ p: Process) {
        for child in ProcessScanner.descendants(of: p.processIdentifier).reversed() { kill(child, SIGTERM) }
        p.terminate()
    }

    func stopAll() { for p in processes.values { end(p) } }

    func clearLogs(_ workspace: UUID) { logs[workspace] = [] }

    private static let errorWords = ["error", "failed", "exception", "err!", "unhandled"]

    private func append(_ chunk: String, service: String, workspace: UUID, isErr: Bool) {
        var list = logs[workspace] ?? []
        for raw in chunk.split(whereSeparator: \.isNewline) {
            let line = Self.stripANSI(String(raw))
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            counter += 1
            let lower = line.lowercased()
            // stderr lines count as errors when they mention one (many tools log progress on stderr);
            // stdout lines only when they start with an error word.
            let mentions = Self.errorWords.contains { lower.contains($0) }
            let startsWith = Self.errorWords.contains { lower.hasPrefix($0) }
            list.append(LogLine(id: counter, time: Date(), service: service, text: line,
                                isError: (isErr && mentions) || startsWith))
        }
        if list.count > Self.maxLines { list.removeFirst(list.count - Self.maxLines) }
        logs[workspace] = list
    }

    nonisolated static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}
