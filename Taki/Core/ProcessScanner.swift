import Darwin
import Foundation

/// A process listening on a local TCP port (a dev server).
struct ListeningServer: Identifiable, Equatable, Sendable {
    var id: String { "\(pid):\(port)" }
    let pid: Int32
    let port: Int
    let command: String          // short process name, e.g. node
    let cwd: String
    let memoryBytes: UInt64
    var project: String? = nil   // the git repository the server runs from, if any
    var startedAt: Date? = nil

    /// The project the server belongs to (its repository), else the process name.
    var label: String { project.map { ($0 as NSString).lastPathComponent } ?? command }
}

/// Finds the repository root that contains a folder (the nearest parent with a .git entry).
/// Answers are cached; a "no repository" answer is checked again after a minute, so a folder
/// that gets `git init` later is seen.
enum ProjectRoot {
    private struct Entry { let root: String?; let at: Date }
    private static let cache = LockedValue<[String: Entry]>([:])
    private static let missRecheck: TimeInterval = 60
    private static let maxEntries = 4_000

    static func of(_ path: String) -> String? {
        guard !path.isEmpty, path != "/" else { return nil }
        let now = Date()
        if let hit = cache.get()[path], hit.root != nil || now.timeIntervalSince(hit.at) < missRecheck { return hit.root }
        var dir = URL(fileURLWithPath: path).standardizedFileURL
        var found: String?
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        while dir.path != "/" && dir.path != home {
            if FileManager.default.fileExists(atPath: dir.appending(path: ".git").path) { found = dir.path; break }
            dir.deleteLastPathComponent()
        }
        cache.mutate { c in
            if c.count >= maxEntries { c.removeAll(keepingCapacity: true) }
            c[path] = Entry(root: found, at: now)
        }
        return found
    }
}

/// Per-process facts from libproc. CPU is measured as a delta between two samples.
enum ProcessScanner {
    /// Every TCP listener owned by this user, from `lsof` (fast, no root: our own processes only).
    static func listeners() -> [ListeningServer] {
        guard let data = ShellEnvironment.runWithStatus("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpcnT"])?.out,   // lsof exits 1 on partial errors
              let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [ListeningServer] = []
        var seen = Set<String>()
        var pid: Int32 = 0
        var cmd = ""
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": cmd = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...])
                else { continue }
                let key = "\(pid):\(port)"
                guard !seen.contains(key), port >= 1024, isDevServer(pid: pid, command: cmd) else { continue }
                seen.insert(key)
                let dir = cwd(of: pid)
                out.append(ListeningServer(pid: pid, port: port, command: displayName(pid: pid, command: cmd), cwd: dir,
                                           memoryBytes: memory(of: pid), project: ProjectRoot.of(dir), startedAt: startTime(of: pid)))
            default: break
            }
        }
        return out.sorted { $0.port < $1.port }
    }

    /// Command-line tools that keep a local port open but are not something you develop
    /// (Android's adb server, language servers, database GUIs).
    static let toolDaemons: Set<String> = ["adb", "rapportd", "sharingd", "identityservicesd", "mysqld", "gopls",
                                           "sourcekit-lsp", "ollama", "syncthing"]

    /// Language runtimes that serve a project. Some live inside an .app bundle (the Python that
    /// `python3 -m http.server` runs is Python.app inside the Command Line Tools), so they are
    /// allowed even there.
    static let runtimes: Set<String> = ["python", "python3", "node", "bun", "deno", "ruby", "php", "java", "dotnet",
                                        "beam.smp", "uvicorn", "gunicorn", "hugo", "caddy", "nginx"]

    /// A dev server is a process you started from a terminal or editor: not a macOS service, not an
    /// app's own helper (Figma's agent, Grammarly, Docker's backend live inside their .app), not a
    /// known tool daemon. A language runtime or anything under node_modules (Electron in a project)
    /// counts wherever it lives. Docker containers are listed separately, by container.
    static func isDevServer(pid: Int32, command: String) -> Bool {
        let p = path(of: pid)
        if p.isEmpty || p.hasPrefix("/System/") || p.hasPrefix("/usr/libexec/") || p.hasPrefix("/usr/sbin/") { return false }
        let name = (p as NSString).lastPathComponent
        if toolDaemons.contains(name) || toolDaemons.contains(command) { return false }
        if runtimes.contains(name.lowercased()) || p.contains("/node_modules/") { return true }
        return !p.contains(".app/Contents/")
    }

    /// lsof truncates names to 9 characters; the executable's file name is the real one. A
    /// `go run` binary in the build cache is named by a hash, so it is shown as "go run".
    static func displayName(pid: Int32, command: String) -> String {
        let p = path(of: pid)
        if p.contains("/go-build/") { return "go run" }
        let name = (p as NSString).lastPathComponent
        if name.lowercased().hasPrefix("python") { return "python" }
        return name.isEmpty ? command : name
    }

    static func startTime(of pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    static func cwd(of pid: Int32) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// Resident memory (phys footprint) of one process.
    static func memory(of pid: Int32) -> UInt64 {
        var usage = rusage_info_v6()
        let r = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return r == 0 ? usage.ri_phys_footprint : 0
    }

    /// Total CPU time (ns) and energy (nJ, when the kernel reports it) of one process.
    static func cpuAndEnergy(of pid: Int32) -> (cpuNs: UInt64, energyNj: UInt64) {
        var usage = rusage_info_v6()
        let r = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        guard r == 0 else { return (0, 0) }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ticks = usage.ri_user_time + usage.ri_system_time
        return (ticks * UInt64(tb.numer) / UInt64(tb.denom), usage.ri_energy_nj)
    }

    /// Every process below `root` in the tree. Pass the poll's parent map when you have one.
    static func descendants(of root: Int32, parents: [Int32: Int32]? = nil) -> [Int32] {
        let parent = parents ?? parentMap()
        var children: [Int32: [Int32]] = [:]
        for (pid, pp) in parent { children[pp, default: []].append(pid) }
        var out: [Int32] = [], frontier = [root]
        while let p = frontier.popLast() {
            for c in children[p] ?? [] { out.append(c); frontier.append(c) }
        }
        return out
    }

    static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// pid -> parent pid for every process we can read.
    static func parentMap() -> [Int32: Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [Int32](repeating: 0, count: Int(count) * 2)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        var parent: [Int32: Int32] = [:]
        for pid in pids.prefix(Int(max(0, n))) where pid > 0 {
            // The short BSD info is readable for every process, including root-owned ones such as
            // `login`, so the chain from an agent up to its terminal app is never cut.
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            if proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size { parent[pid] = Int32(info.pbsi_ppid) }
        }
        return parent
    }

    static func isDescendant(_ pid: Int32, of root: Int32, parents: [Int32: Int32]) -> Bool {
        var p = pid, hops = 0
        while let pp = parents[p], pp > 1, hops < 64 {
            if pp == root { return true }
            p = pp; hops += 1
        }
        return false
    }

    static func path(of pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
    }

    /// The app an agent runs in (Terminal, iTerm, Ghostty, cmux, Cursor, Taki...), from the first
    /// ancestor whose executable lives inside a .app bundle.
    static func hostApp(of pid: Int32, parents: [Int32: Int32]) -> String? {
        var p = pid, hops = 0
        while let pp = parents[p], pp > 1, hops < 64 {
            let path = path(of: pp)
            if let r = path.range(of: ".app/Contents/MacOS/") {
                return (String(path[..<r.lowerBound]) as NSString).lastPathComponent
            }
            p = pp; hops += 1
        }
        return nil
    }
}
