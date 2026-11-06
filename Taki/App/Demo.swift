import Foundation

/// Sample data for screenshots: launch with `-TakiDemo` (see the README). In demo mode Taki scans
/// nothing, starts no process (services, chats, Clean up and Stop do nothing), sends no
/// notification, writes no widget data and keeps its files in a temporary folder, so screenshots
/// show no one's real projects and the real files are never touched.
enum Demo {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-TakiDemo")

    struct Chat {
        let folder: String
        let title: String
        let messages: [ChatSession.Message]
    }

    struct Snapshot {
        var workspaces: [Workspace] = []
        var facts: [UUID: ProjectFacts] = [:]
        var agents: [LiveAgent] = []
        var servers: [ListeningServer] = []
        var ports: [UUID: Int] = [:]
        var memory: [UUID: UInt64] = [:]
        var containers: [DockerContainer] = []
        var usage = UsageSnapshot()
        var system = SystemSnapshot()
        var limits: RateLimits?
        var running: [UUID: ServiceRunner.Running] = [:]
        var logs: [UUID: [LogLine]] = [:]
        var stats: [UUID: ResourceMonitor.Stats] = [:]
        var cleanup: [CleanupItem] = []
        var chats: [Chat] = []
    }

    private static let mb: UInt64 = 1_048_576

    static func snapshot(now: Date = Date()) -> Snapshot {
        var d = Snapshot()
        let code = NSHomeDirectory() + "/code"
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        // Workspaces, with the facts Taki would read from their files.
        let web = Workspace.Service(name: "web", command: "pnpm dev", port: 3000)
        let emails = Workspace.Service(name: "emails", command: "pnpm email", port: 3001)
        let landing = Workspace(name: "landing-page", folder: code + "/landing-page", services: [web, emails],
                                envNames: ["DATABASE_URL", "STRIPE_SECRET_KEY"], linkName: "landing-page")
        let apiService = Workspace.Service(name: "api", command: "pnpm start:dev", port: 4000)
        let api = Workspace(name: "api", folder: code + "/api", services: [apiService], linkName: "api")
        let studio = Workspace(name: "social-studio", folder: code + "/social-studio", linkName: "social-studio")
        let portfolio = Workspace(name: "portfolio", folder: code + "/portfolio", linkName: "portfolio")
        let mobile = Workspace(name: "mobile", folder: code + "/mobile", linkName: "mobile")
        d.workspaces = [landing, api, studio, portfolio, mobile]
        d.facts = [
            landing.id: ProjectFacts(framework: "Next.js 15", symbol: "shippingbox.fill", logo: "nextdotjs", branch: "main"),
            api.id: ProjectFacts(framework: "NestJS 11", symbol: "shippingbox.fill", logo: "nestjs", branch: "feat/rate-limits"),
            studio.id: ProjectFacts(framework: "Next.js 15", symbol: "shippingbox.fill", logo: "nextdotjs", branch: "main"),
            portfolio.id: ProjectFacts(framework: "Vite 6", symbol: "shippingbox.fill", logo: "vite", branch: "main"),
            mobile.id: ProjectFacts(framework: "Expo 53", symbol: "shippingbox.fill", logo: "expo", branch: "develop"),
        ]

        // Services Taki runs, with their output.
        d.running = [web.id: .init(pid: 0, startedAt: ago(42)), emails.id: .init(pid: 0, startedAt: ago(41)),
                     apiService.id: .init(pid: 0, startedAt: ago(18))]
        d.ports = [web.id: 3000, emails.id: 3001, apiService.id: 4000]
        d.memory = [web.id: 286 * mb, emails.id: 126 * mb, apiService.id: 198 * mb]
        let lines: [(Double, String, String, Bool)] = [
            (14.2, "web", "GET / 200 in 41ms", false),
            (14.0, "web", "GET /pricing 200 in 63ms", false),
            (13.6, "emails", "Rendered welcome.tsx in 12ms", false),
            (13.1, "web", "✓ Compiled /pricing in 312ms (1,204 modules)", false),
            (12.8, "web", "GET /api/plans 200 in 18ms", false),
            (12.2, "emails", "Preview ready on :3001", false),
            (11.5, "web", "GET /_next/static/chunks/app.js 304 in 3ms", false),
            (10.4, "web", "○ Compiling /checkout ...", false),
            (10.2, "web", "✓ Compiled /checkout in 488ms", false),
            (9.9, "web", "GET /checkout 200 in 522ms", false),
            (8.7, "web", "GET /api/session 200 in 9ms", false),
            (7.3, "emails", "Rendered receipt.tsx in 9ms", false),
            (6.1, "web", "GET /blog 200 in 37ms", false),
            (5.4, "web", "GET /blog/launch-week 200 in 58ms", false),
            (4.2, "emails", "Rendered reset-password.tsx in 11ms", false),
            (3.3, "web", "○ Compiling /dashboard ...", false),
            (3.1, "web", "✓ Compiled /dashboard in 401ms", false),
            (2.9, "web", "GET /dashboard 200 in 433ms", false),
            (2.2, "web", "GET /api/usage 500 in 22ms", true),
            (1.9, "web", "Error: STRIPE_PRICE_ID is not set", true),
            (1.1, "web", "GET /api/usage 200 in 19ms", false),
            (0.4, "web", "GET / 200 in 28ms", false),
        ]
        d.logs = [landing.id: lines.enumerated().map { i, l in
            LogLine(id: i, time: ago(l.0), service: l.1, text: l.2, isError: l.3)
        }]
        var stats = ResourceMonitor.Stats()
        stats.cpu = 12
        stats.cpuPeak = 38
        stats.memory = 412 * mb
        stats.watts = 3.1
        stats.wattsThisHour = [2.6, 3.0, 3.4, 3.1]
        stats.cpuHistory = [6, 9, 14, 11, 8, 13, 12]
        stats.memHistory = [380, 386, 392, 398, 401, 407, 412]
        d.stats[landing.id] = stats

        // Agents, from three tools, each in its project.
        func agent(_ id: String, _ tool: LiveAgent.Tool, _ folder: String, _ status: LiveAgent.Status, _ minutes: Double,
                   _ task: String, context: Double, host: String, servers: Int = 0) -> LiveAgent {
            LiveAgent(id: id, pid: 0, tool: tool, cwd: folder, name: (folder as NSString).lastPathComponent, status: status,
                      startedAt: ago(minutes + 20), statusSince: ago(minutes), task: task,
                      contextTokens: Int(context * 200_000), hostApp: host, serverCount: servers, project: folder)
        }
        d.agents = [
            agent("2B1F6E0A-0001-4C5A-9C11-6A0D5E3F0001", .claude, landing.folder, .working, 42, "Build the pricing section",
                  context: 0.86, host: "Taki", servers: 2),
            agent("2B1F6E0A-0002-4C5A-9C11-6A0D5E3F0002", .claude, landing.folder, .working, 6, "Refactor auth middleware",
                  context: 0.31, host: "Ghostty"),
            agent("codex-1", .codex, landing.folder, .idle, 8, "Notes sync", context: 0, host: "Terminal"),
            agent("2B1F6E0A-0004-4C5A-9C11-6A0D5E3F0004", .claude, api.folder, .waiting, 2, "Add rate limits to the public API",
                  context: 0.44, host: "Taki", servers: 1),
            agent("cursor-1", .cursor, studio.folder, .idle, 25, "Caption editor polish", context: 0, host: "Cursor"),
        ]

        // Dev servers started outside Taki, and Docker containers.
        d.servers = [
            ListeningServer(pid: 0, port: 5173, command: "node", cwd: code + "/playground", memoryBytes: 94 * mb,
                            project: code + "/playground", startedAt: ago(75)),
            ListeningServer(pid: 0, port: 6006, command: "node", cwd: code + "/ui-kit", memoryBytes: 180 * mb,
                            project: code + "/ui-kit", startedAt: ago(130)),
        ]
        d.containers = [
            DockerContainer(id: "c1", name: "api-postgres-1", image: "postgres:17", ports: [5432], status: "Up 3 hours (healthy)",
                            project: "api", workingDir: api.folder),
            DockerContainer(id: "c2", name: "api-redis-1", image: "redis:7", ports: [6379], status: "Up 3 hours",
                            project: "api", workingDir: api.folder),
        ]

        // Usage, limits and the Mac.
        d.usage.claudeTokensToday = 4_180_000
        d.usage.codexTokensToday = 412_000
        d.usage.claudeTokensWeek = 31_600_000
        d.usage.codexTokensWeek = 2_900_000
        d.usage.codexWeekUsed = 0.03
        d.usage.codexWeekAsOf = ago(60 * 20)
        d.usage.sessionsPerHour = [1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 2, 2, 1, 1, 1, 1, 2, 3, 4, 2]
        d.usage.tokensPerHour = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 120, 260, 180, 90, 60, 20, 8]
            .map { $0 * 1_000 }
        d.usage.sessions24h = 16
        d.limits = RateLimits(fiveHourUsed: 0.34, fiveHourResets: now.addingTimeInterval(2.2 * 3600),
                              weekUsed: 0.52, weekResets: now.addingTimeInterval(3 * 86_400))
        d.system.usedMemory = UInt64(Double(d.system.totalMemory) * 0.68)
        d.system.apps = [("Xcode", 3_100), ("Google Chrome", 2_400), ("Docker", 1_600), ("Figma", 820), ("Slack", 610),
                         ("Notion", 450)].map { SystemSnapshot.App(name: $0.0, memory: UInt64($0.1) * mb) }

        // Clean up's sample items name paths that do not exist, and Clean up does nothing in demo mode.
        let none = FileManager.default.temporaryDirectory.appending(path: "TakiDemo/none").path
        d.cleanup = [
            CleanupItem(kind: .worktrees, path: none + "/pricing-v1", bytes: 1_240 * mb,
                        label: "landing-page/.claude/worktrees/pricing-v1"),
            CleanupItem(kind: .caches, path: none + "/portfolio-next", bytes: 640 * mb, label: "portfolio/.next"),
            CleanupItem(kind: .transcripts, path: none + "/old-sessions", bytes: 180 * mb, label: "212 transcripts older than 30 days"),
        ]

        d.chats = [Chat(folder: landing.folder, title: "Pricing page copy", messages: [
            .init(role: .user, text: "Tighten the pricing page copy and make the yearly toggle remember the choice."),
            .init(role: .assistant, text: "I'll read the pricing section first, then change the copy and store the toggle in a cookie so it survives a reload."),
            .init(role: .tool, text: "Read", detail: "app/pricing/page.tsx"),
            .init(role: .tool, text: "Edit", detail: "app/pricing/plans.tsx"),
            .init(role: .assistant, text: "Done. The three plans now lead with what you get, the yearly toggle is saved in a `billing` cookie, and the page reads it on the server so there is no flash on load."),
        ])]
        return d
    }
}
