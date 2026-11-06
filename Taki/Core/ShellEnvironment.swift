import Foundation

/// The owner's login-shell environment. A GUI app launched from Finder gets a bare PATH, so
/// `claude`, `codex`, `node` and `git` would not be found. We read the real environment once
/// from a login shell and hand it to every process Taki starts.
enum ShellEnvironment {
    private static let cache = LockedValue<[String: String]?>(nil)

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
                              timeout: TimeInterval? = nil) -> (out: Data, status: Int32)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
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
