import Foundation

/// The owner's login-shell environment. A GUI app launched from Finder gets a bare PATH, so
/// `claude`, `codex`, `node` and `git` would not be found. We read the real environment once
/// from a login shell and hand it to every process Taki starts.
enum ShellEnvironment {
    private static let cache = LockedValue<[String: String]?>(nil)

    /// Variables Claude Code puts into the processes it starts. When Taki itself was started from
    /// inside a Claude Code session they reach Taki, and every tab and chat would inherit them:
    /// Claude then treats itself as a child session and stops saving transcripts, and the parent
    /// session's messaging token leaks into every shell. Only these session markers go; the
    /// owner's own Claude settings (CLAUDE_CODE_USE_BEDROCK, CLAUDE_CODE_OAUTH_TOKEN, ...) stay.
    static let inheritedAgentMarkers: Set<String> = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "AI_AGENT",
        "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SSE_PORT",
        "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_PLUGIN_DIRS",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
    ]

    /// Claude Code also sets GIT_EDITOR=true (an editor that does nothing) so git never opens one
    /// under it; a shell in Taki must get the owner's editor back. A real editor setting stays.
    static func isInheritedAgentMarker(_ key: String, value: String? = nil) -> Bool {
        if key == "GIT_EDITOR" { return value == "true" }
        return inheritedAgentMarkers.contains(key)
    }

    /// Removes inherited agent markers from Taki's own environment, once at launch and before
    /// anything is spawned, so no child process (tab, chat, service, scan) ever sees them.
    static func dropInheritedAgentMarkers() {
        for (key, value) in ProcessInfo.processInfo.environment where isInheritedAgentMarker(key, value: value) { unsetenv(key) }
    }

    static func load() -> [String: String] {
        if let cached = cache.get() { return cached }
        var env = ProcessInfo.processInfo.environment
        if let data = run("/bin/zsh", ["-lc", "env -0"]) {
            for entry in data.split(separator: 0) {
                guard let line = String(data: Data(entry), encoding: .utf8),
                      let eq = line.firstIndex(of: "=") else { continue }
                env[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        cache.set(env)
        return env
    }

    /// Absolute path of an executable on the login PATH, or nil.
    static func which(_ name: String) -> String? {
        let path = load()["PATH"] ?? "/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Runs a short command and returns stdout, or nil when it fails to start, exits non-zero or
    /// runs past `timeout` seconds (it is then stopped).
    static func run(_ launchPath: String, _ args: [String], cwd: String? = nil, timeout: TimeInterval? = nil) -> Data? {
        guard let r = runWithStatus(launchPath, args, cwd: cwd, timeout: timeout), r.status == 0 else { return nil }
        return r.out
    }

    /// Runs a short command; stdout and the exit status, or nil when it fails to start. With a
    /// `timeout` the command is stopped when it takes longer (a hung daemon never blocks the caller).
    static func runWithStatus(_ launchPath: String, _ args: [String], cwd: String? = nil,
                              timeout: TimeInterval? = nil, environment: [String: String]? = nil,
                              includeStderr: Bool = false) -> (out: Data, status: Int32)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let environment { p.environment = environment }
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = includeStderr ? out : FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let watchdog = timeout.map { limit in
            let item = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: item)
            return item
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog?.cancel()
        return (data, p.terminationStatus)
    }
}

/// A tiny lock-protected box for values shared across threads.
final class LockedValue<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    /// Read and change the value in one step, so two threads never lose each other's update.
    func mutate<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
