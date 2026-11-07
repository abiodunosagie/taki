import Foundation

/// Sample data for screenshots: launch with `-TakiDemo` (see the README). In demo mode Taki scans
/// nothing and starts nothing, so screenshots show no one's real projects.
enum Demo {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-TakiDemo")

    struct Snapshot {
        var agents: [LiveAgent] = []
        var servers: [ListeningServer] = []
        var usage = UsageSnapshot()
        var system = SystemSnapshot()
        var limits: RateLimits?
    }

    private static let mb: UInt64 = 1_048_576

    static func snapshot(now: Date = Date()) -> Snapshot {
        var d = Snapshot()
        let code = NSHomeDirectory() + "/code"
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        func agent(_ id: String, _ tool: LiveAgent.Tool, _ folder: String, _ status: LiveAgent.Status, _ minutes: Double,
                   _ task: String, context: Double, host: String) -> LiveAgent {
            LiveAgent(id: id, pid: 0, tool: tool, cwd: folder, name: (folder as NSString).lastPathComponent, status: status,
                      startedAt: ago(minutes + 20), statusSince: ago(minutes), task: task,
                      contextTokens: Int(context * 200_000), hostApp: host, project: folder)
        }
        d.agents = [
            agent("2B1F6E0A-0001-4C5A-9C11-6A0D5E3F0001", .claude, code + "/landing-page", .working, 42,
                  "Build the pricing section", context: 0.86, host: "Terminal"),
            agent("codex-1", .codex, code + "/landing-page", .idle, 8, "Notes sync", context: 0, host: "Terminal"),
            agent("2B1F6E0A-0004-4C5A-9C11-6A0D5E3F0004", .claude, code + "/api", .waiting, 2,
                  "Add rate limits to the public API", context: 0.44, host: "Ghostty"),
        ]
        d.servers = [
            ListeningServer(pid: 0, port: 3000, command: "node", cwd: code + "/landing-page", memoryBytes: 286 * mb,
                            project: code + "/landing-page", startedAt: ago(42)),
            ListeningServer(pid: 0, port: 5173, command: "node", cwd: code + "/playground", memoryBytes: 94 * mb,
                            project: code + "/playground", startedAt: ago(75)),
        ]
        d.usage.claudeTokensToday = 4_180_000
        d.usage.claudeTokensWeek = 31_600_000
        d.usage.sessionsPerHour = [1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 2, 2, 1, 1, 1, 1, 2, 3, 4, 2]
        d.usage.sessions24h = 16
        d.limits = RateLimits(fiveHourUsed: 0.34, fiveHourResets: now.addingTimeInterval(2.2 * 3600),
                              weekUsed: 0.52, weekResets: now.addingTimeInterval(3 * 86_400))
        d.system.usedMemory = UInt64(Double(d.system.totalMemory) * 0.68)
        d.system.apps = [("Xcode", 3_100), ("Google Chrome", 2_400), ("Figma", 820), ("Slack", 610)]
            .map { SystemSnapshot.App(name: $0.0, memory: UInt64($0.1) * mb) }
        return d
    }
}
