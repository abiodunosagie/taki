import Foundation

/// Token totals and session activity from local transcripts. Nothing leaves the Mac.
/// Claude: `~/.claude/projects/*/*.jsonl` assistant lines carry `message.usage` and `timestamp`.
/// Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` `token_count` events carry usage and
/// `rate_limits` (primary = 5 hour, secondary = week, when the CLI reports them).
struct UsageSnapshot: Equatable, Sendable {
    var claudeTokensToday = 0
    var claudeTokensWeek = 0
    var codexTokensToday = 0
    var codexTokensWeek = 0
    var codexWeekUsed: Double?          // 0...1
    var codexWeekAsOf: Date?
    var sessionsPerHour: [Int] = Array(repeating: 0, count: 24)   // index 23 = the current hour
    var tokensPerHour: [Int] = Array(repeating: 0, count: 24)
    var sessions24h = 0

    var tokensToday: Int { claudeTokensToday + codexTokensToday }
}

enum UsageScanner {
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {   // read-only after init
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// One usage event: when, how many tokens, which session.
    struct Record: Sendable {
        let time: Date
        let tokens: Int
        let session: String
    }

    /// Per-file read position and the records parsed so far, so each scan reads only the lines
    /// appended since the last one (transcripts grow to hundreds of MB; re-reading them every
    /// 30 s cost about 1 GB of churn).
    struct FileState: Sendable {
        var offset: UInt64 = 0
        var records: [Record] = []
        var codexWeek: (used: Double, at: Date)? = nil
        var seenMessages: Set<String> = []   // Claude writes one line per content block, same usage each
    }

    private static let cache = LockedValue<[String: FileState]>([:])

    static func scan(now: Date = Date()) -> UsageSnapshot {
        var snap = UsageSnapshot()
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: now)
        let weekStart = now.addingTimeInterval(-7 * 86_400)
        let hourStart = cal.dateInterval(of: .hour, for: now)?.start ?? now
        let windowStart = hourStart.addingTimeInterval(-23 * 3_600)

        let claudeFiles = recentFiles(under: AgentScanner.claudeDir.appending(path: "projects"), since: weekStart)
        let codexFiles = recentFiles(under: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions"),
                                     since: weekStart)
        var states = cache.get()
        var next: [String: FileState] = [:]
        // Each file's read buffers are freed as soon as it is parsed (a background task has no
        // run loop to drain autoreleased NSData, which held hundreds of MB).
        for url in claudeFiles {
            autoreleasepool { next[url.path] = advance(url, state: states[url.path] ?? FileState(), codex: false) }
        }
        for url in codexFiles {
            autoreleasepool { next[url.path] = advance(url, state: states[url.path] ?? FileState(), codex: true) }
        }
        states = next
        cache.set(states)

        var sessionHours: [Int: Set<String>] = [:]
        let codexPaths = Set(codexFiles.map(\.path))
        for (path, st) in states {
            let isCodex = codexPaths.contains(path)
            for r in st.records where r.time >= weekStart {
                if isCodex { snap.codexTokensWeek += r.tokens } else { snap.claudeTokensWeek += r.tokens }
                if r.time >= dayStart {
                    if isCodex { snap.codexTokensToday += r.tokens } else { snap.claudeTokensToday += r.tokens }
                }
                if r.time >= windowStart {
                    let b = min(23, Int(r.time.timeIntervalSince(windowStart) / 3_600))
                    snap.tokensPerHour[b] += r.tokens
                    sessionHours[b, default: []].insert(r.session)
                }
            }
            if let cw = st.codexWeek, snap.codexWeekAsOf.map({ cw.at > $0 }) ?? true {
                snap.codexWeekUsed = cw.used
                snap.codexWeekAsOf = cw.at
            }
        }
        for (b, ids) in sessionHours { snap.sessionsPerHour[b] = ids.count }
        snap.sessions24h = Set(sessionHours.values.flatMap { $0 }).count
        return snap
    }

    /// Reads the complete lines appended to `url` since `state.offset`.
    static func advance(_ url: URL, state: FileState, codex: Bool) -> FileState {
        var st = state
        guard let h = try? FileHandle(forReadingFrom: url) else { return st }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < st.offset { st = FileState() }               // the file was replaced: start over
        guard size > st.offset else { return st }
        try? h.seek(toOffset: st.offset)
        let chunk = Int(min(size - st.offset, 16 * 1_048_576))      // at most 16 MB per pass, the rest next scan
        guard let data = try? h.read(upToCount: chunk),
              let lastNL = data.lastIndex(of: 0x0A) else { return st }
        let complete = data[data.startIndex...lastNL]
        st.offset += UInt64(complete.count)
        let sid = url.deletingPathExtension().lastPathComponent
        let needle = Data((codex ? "token_count" : "\"usage\"").utf8)
        for line in complete.split(separator: 0x0A) where line.range(of: needle) != nil {
            autoreleasepool {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let ts = (o["timestamp"] as? String).flatMap(iso.date(from:)) else { return }
                if codex {
                    guard o["type"] as? String == "event_msg", let p = o["payload"] as? [String: Any],
                          p["type"] as? String == "token_count" else { return }
                    if let info = p["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any] {
                        let n = (last["input_tokens"] as? Int ?? 0) + (last["output_tokens"] as? Int ?? 0)
                        st.records.append(Record(time: ts, tokens: n, session: sid))
                    }
                    if let rl = p["rate_limits"] as? [String: Any], let sec = rl["secondary"] as? [String: Any],
                       let pct = sec["used_percent"] as? Double {
                        st.codexWeek = (pct / 100, ts)
                    }
                } else {
                    guard let msg = o["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] else { return }
                    if let mid = msg["id"] as? String, !st.seenMessages.insert(mid).inserted { return }
                    let n = (u["input_tokens"] as? Int ?? 0) + (u["output_tokens"] as? Int ?? 0)
                        + (u["cache_creation_input_tokens"] as? Int ?? 0)
                    st.records.append(Record(time: ts, tokens: n, session: sid))
                }
            }
        }
        let keep = Date().addingTimeInterval(-8 * 86_400)
        st.records.removeAll { $0.time < keep }               // only the window the cards show
        return st
    }

    /// `.jsonl` files modified since `since`, walking at most four levels.
    static func recentFiles(under root: URL, since: Date) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e {
            if e.level > 4 { e.skipDescendants(); continue }
            guard url.pathExtension == "jsonl",
                  let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  m >= since else { continue }
            out.append(url)
        }
        return out
    }
}
