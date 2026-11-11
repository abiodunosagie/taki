import Foundation

/// Codex keeps each session in ~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl, whose
/// first line is a `session_meta` record with the session's id and the folder it ran in (read
/// from Codex's own files, 2026-11). Taki uses that to reopen a Codex tab on its folder's latest
/// session after a relaunch, and to start fresh when the folder has none.
enum CodexSessions {
    static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions") }

    /// How many of the newest session files to look through: enough for weeks of work, cheap at launch.
    static let lookback = 400

    /// The newest session id that ran in `folder`, or nil.
    static func latest(in folder: String, root: URL = root) -> String? {
        let target = canonical(folder)
        for file in newestFiles(under: root).prefix(lookback) {
            guard let meta = firstLine(of: file), meta.cwd == target else { continue }
            return meta.id
        }
        return nil
    }

    /// Paths sort by date because the folders are YYYY/MM/DD and the names start with the time.
    static func newestFiles(under root: URL) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walk.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
            .sorted { $0.path > $1.path }
    }

    struct Meta: Equatable { let id: String; let cwd: String }

    /// The first line holds Codex's whole system prompt, so it runs past 18 KB: read in chunks
    /// until the newline, up to a cap that keeps a broken file from being read whole.
    static let maxFirstLine = 1 << 20

    static func firstLine(of file: URL) -> Meta? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        var line = Data()
        while line.count < maxFirstLine {
            guard let chunk = try? h.read(upToCount: 65_536), !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: 0x0A) {
                line.append(chunk[chunk.startIndex..<newline])
                return parse(line)
            }
            line.append(chunk)
        }
        return parse(line)     // a one-line file with no trailing newline
    }

    static func parse(_ line: Data) -> Meta? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let id = payload["id"] as? String, UUID(uuidString: id) != nil,
              let cwd = payload["cwd"] as? String else { return nil }
        return Meta(id: id.lowercased(), cwd: canonical(cwd))
    }

    /// /tmp and /private/tmp, or a folder reached through a symlink, name the same place.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
