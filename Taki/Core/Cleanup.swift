import AppKit
import Darwin
import Foundation
import Observation

/// What a finished agent session left behind. Everything is listed first and goes to the Trash
/// (undoable). Never touches a worktree with uncommitted changes or anything outside these rules.
struct CleanupItem: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case worktrees = "Stale worktrees", caches = "Build caches", transcripts = "AI transcripts",
             orphans = "Orphan processes"
        var detail: String {
            switch self {
            case .worktrees: "Agent worktrees whose branch is merged."
            case .caches: ".next, .vite, .turbo in workspaces idle for a day."
            case .transcripts: "Claude Code and Codex transcripts older than 30 days."
            case .orphans: "Leftover processes from agents that ended."
            }
        }
    }
    var id: String { "\(kind.rawValue):\(path)\(pid.map { ":\($0)" } ?? "")" }
    let kind: Kind
    let path: String
    let bytes: UInt64
    var pid: Int32? = nil
    var label: String
}

@MainActor
@Observable
final class CleanupModel {
    private(set) var items: [CleanupItem] = []
    private(set) var scanning = false
    private(set) var lastScan: Date?
    var excluded: Set<String> = []

    /// Demo mode only: sample leftovers, nothing on disk is scanned.
    func showDemo(_ items: [CleanupItem]) {
        self.items = items
        lastScan = Date()
    }

    var totalBytes: UInt64 { items.filter { !excluded.contains($0.id) && $0.kind != .orphans }.reduce(0) { $0 + $1.bytes } }

    func bytes(_ kind: CleanupItem.Kind) -> UInt64 {
        items.filter { $0.kind == kind && !excluded.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    func scan(workspaces: [Workspace], liveAgentCwds: [String], busyFolders: Set<String>) {
        guard !Demo.isOn else { return }
        guard !scanning else { return }
        scanning = true
        let folders = workspaces.map(\.folder)
        Task.detached(priority: .utility) {
            let found = CleanupScanner.scan(workspaceFolders: folders, liveAgentCwds: liveAgentCwds, busyFolders: busyFolders)
            await MainActor.run {
                self.items = found
                self.scanning = false
                self.lastScan = Date()
            }
        }
    }

    /// Moves every selected file item to the Trash and ends selected orphan processes. Each item
    /// is checked again right before it is touched (the list can be minutes old), off the main actor.
    func clean(liveAgentCwds: [String]) async -> (moved: Int, failed: Int, skipped: Int) {
        guard !Demo.isOn else { return (0, 0, items.count) }    // sample items name no real files
        let chosen = items.filter { !excluded.contains($0.id) }
        let result = await Task.detached(priority: .userInitiated) { () -> (Int, Int, Int, [CleanupItem]) in
            var moved = 0, failed = 0, skipped = 0
            var done: [CleanupItem] = []
            for item in chosen {
                guard CleanupScanner.stillSafe(item, liveAgentCwds: liveAgentCwds) else { skipped += 1; continue }
                if let pid = item.pid {
                    if kill(pid, SIGTERM) == 0 { moved += 1; done.append(item) } else { failed += 1 }
                    continue
                }
                // Find the owning repo BEFORE the folder moves, then prune its worktree list.
                let main = item.kind == .worktrees ? CleanupScanner.mainRepo(ofWorktree: item.path) : nil
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                    if let main { _ = ShellEnvironment.run("/usr/bin/git", ["-C", main, "worktree", "prune"]) }
                    moved += 1
                    done.append(item)
                } catch { failed += 1 }
            }
            return (moved, failed, skipped, done)
        }.value
        items.removeAll { result.3.contains($0) }
        return (result.0, result.1, result.2)
    }
}

enum CleanupScanner {
    static let cacheNames = [".next", ".vite", ".turbo", ".parcel-cache", ".svelte-kit", ".nuxt", ".angular"]
    static let devServerCommands: Set<String> = ["node", "esbuild", "vite", "next-server", "bun", "deno"]
    static let cacheIdle: TimeInterval = 86_400
    static let transcriptAge: TimeInterval = 30 * 86_400

    static func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    /// True when `path` is `folder` or inside it, comparing whole path components.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        let p = real(path), f = real(folder)
        return p == f || p.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }

    static func scan(workspaceFolders: [String], liveAgentCwds: [String], busyFolders: Set<String>) -> [CleanupItem] {
        var out: [CleanupItem] = []
        let fm = FileManager.default
        for folder in workspaceFolders where !busyFolders.contains(folder) {   // never under a running service
            for name in cacheNames {
                let path = folder + "/" + name
                guard fm.fileExists(atPath: path), newestChange(in: path) < Date().addingTimeInterval(-cacheIdle)
                else { continue }
                out.append(.init(kind: .caches, path: path, bytes: size(path),
                                 label: "\((folder as NSString).lastPathComponent)/\(name)"))
            }
        }
        var seenRepos = Set<String>()
        for folder in workspaceFolders {
            guard let main = mainRepo(ofWorktree: folder), seenRepos.insert(real(main)).inserted else { continue }
            out += staleWorktrees(mainRepo: main, liveAgentCwds: liveAgentCwds)
        }
        let cutoff = Date().addingTimeInterval(-transcriptAge)
        let home = fm.homeDirectoryForCurrentUser
        for root in [home.appending(path: ".claude/projects"), home.appending(path: ".codex/sessions")] {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey])
            else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey])
                guard v?.isSymbolicLink != true, let m = v?.contentModificationDate, m < cutoff else { continue }
                out.append(.init(kind: .transcripts, path: url.path, bytes: UInt64(v?.fileSize ?? 0),
                                 label: url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent))
            }
        }
        out += orphans(liveAgentCwds: liveAgentCwds)
        return out
    }

    /// Newest modification time of anything in a cache folder (a folder's own date does not change
    /// when files deep inside it are rewritten). Stops early once a recent file is found.
    static func newestChange(in path: String) -> Date {
        var newest = Date.distantPast
        let recent = Date().addingTimeInterval(-cacheIdle)
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
                                                     includingPropertiesForKeys: [.contentModificationDateKey]) else { return newest }
        for case let url as URL in e {
            if let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > newest {
                newest = m
                if newest > recent { break }
            }
        }
        return newest
    }

    /// The repository's default branch: origin/HEAD, else main, else master.
    static func defaultBranch(_ repo: String) -> String? {
        if let d = ShellEnvironment.run("/usr/bin/git", ["-C", repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"]),
           let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        for b in ["main", "master"] where ShellEnvironment.run("/usr/bin/git", ["-C", repo, "rev-parse", "--verify", "--quiet", b]) != nil {
            return b
        }
        return nil
    }

    /// Linked worktrees of `mainRepo` that are safe to remove: the branch has its own commits and
    /// all of them are in the default branch, the tree is clean (git status succeeded and printed
    /// nothing), and no live agent works inside it. The main worktree is never a candidate.
    static func staleWorktrees(mainRepo: String, liveAgentCwds: [String]) -> [CleanupItem] {
        guard let base = defaultBranch(mainRepo),
              let d = ShellEnvironment.run("/usr/bin/git", ["-C", mainRepo, "worktree", "list", "--porcelain"]),
              let text = String(data: d, encoding: .utf8) else { return [] }
        var out: [CleanupItem] = []
        for (i, block) in text.components(separatedBy: "\n\n").enumerated() where i > 0 {   // block 0 = main worktree
            var path = "", branch = ""
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst(18)) }
            }
            guard !path.isEmpty, !branch.isEmpty, real(path) != real(mainRepo),
                  isSafeWorktree(path: path, branch: branch, base: base, repo: mainRepo, liveAgentCwds: liveAgentCwds)
            else { continue }
            out.append(.init(kind: .worktrees, path: path, bytes: size(path),
                             label: "\((path as NSString).abbreviatingWithTildeInPath) (\(branch), merged into \(base))"))
        }
        return out
    }

    static func isSafeWorktree(path: String, branch: String, base: String, repo: String, liveAgentCwds: [String]) -> Bool {
        // A linked worktree has a .git FILE; a directory means it is a real repository.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &isDir), !isDir.boolValue else { return false }
        guard !liveAgentCwds.contains(where: { isInside($0, path) }) else { return false }
        guard let st = ShellEnvironment.runWithStatus("/usr/bin/git", ["-C", path, "status", "--porcelain", "--ignored=no"]),
              st.status == 0, st.out.isEmpty else { return false }
        // Every commit of the branch is already in the default branch ...
        guard let own = ShellEnvironment.run("/usr/bin/git", ["-C", repo, "rev-list", "--count", "\(base)..\(branch)"]),
              let ahead = Int(String(decoding: own, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        if ahead > 0 { return false }                                   // commits not yet in the default branch
        // ... and the branch had commits of its own at some point. Its reflog has a line per commit
        // made on it; a branch that was only created (fresh, or behind the base) has just one.
        guard let log = ShellEnvironment.run("/usr/bin/git", ["-C", repo, "reflog", "show", "--format=%H", "refs/heads/\(branch)"])
        else { return false }
        return String(decoding: log, as: UTF8.self).split(separator: "\n").count > 1
    }

    static func mainRepo(ofWorktree path: String) -> String? {
        guard let d = ShellEnvironment.run("/usr/bin/git", ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"]),
              let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.hasSuffix("/.git") else { return nil }
        return (s as NSString).deletingLastPathComponent
    }

    /// Dev-server processes whose parent died (re-parented to launchd, ppid 1), owned by this user,
    /// running from an agent area: a `.claude` or `.codex` folder or a `worktrees` folder (matched
    /// as whole path components), and not inside any live agent's folder.
    static func orphans(liveAgentCwds: [String]) -> [CleanupItem] {
        guard let d = ShellEnvironment.run("/bin/ps", ["-axo", "pid=,ppid=,uid=,comm="]),
              let text = String(data: d, encoding: .utf8) else { return [] }
        var out: [CleanupItem] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), parts[1] == "1", UInt32(parts[2]) == getuid() else { continue }
            let base = (String(parts[3]) as NSString).lastPathComponent
            let cwd = ProcessScanner.cwd(of: pid)
            guard devServerCommands.contains(base), isAgentArea(cwd),
                  !liveAgentCwds.contains(where: { isInside(cwd, $0) }) else { continue }
            out.append(.init(kind: .orphans, path: cwd, bytes: ProcessScanner.memory(of: pid), pid: pid,
                             label: "\(base) (pid \(pid)) in \((cwd as NSString).abbreviatingWithTildeInPath)"))
        }
        return out
    }

    static func isAgentArea(_ cwd: String) -> Bool {
        let parts = cwd.split(separator: "/").map(String.init)
        return parts.contains(".claude") || parts.contains(".codex") || parts.contains("worktrees")
    }

    /// Re-checks an item right before acting: the orphan is still the same orphan (ppid 1, same
    /// command family, same folder), the worktree is still safe, the file still exists.
    static func stillSafe(_ item: CleanupItem, liveAgentCwds: [String]) -> Bool {
        if let pid = item.pid {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_ppid == 1,
                  info.pbsi_uid == getuid() else { return false }
            let base = (ProcessScanner.path(of: pid) as NSString).lastPathComponent
            return devServerCommands.contains(base) && ProcessScanner.cwd(of: pid) == item.path
        }
        guard FileManager.default.fileExists(atPath: item.path) else { return false }
        if item.kind == .worktrees {
            guard let main = mainRepo(ofWorktree: item.path), let base = defaultBranch(main),
                  let head = ShellEnvironment.run("/usr/bin/git", ["-C", item.path, "symbolic-ref", "--short", "HEAD"]) else { return false }
            let branch = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return real(item.path) != real(main)
                && isSafeWorktree(path: item.path, branch: branch, base: base, repo: main, liveAgentCwds: liveAgentCwds)
        }
        return true
    }

    static func size(_ path: String) -> UInt64 {
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
                                                     includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in e {
            total += UInt64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
