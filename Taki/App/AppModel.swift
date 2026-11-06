import AppKit
import Foundation
import Observation
import WidgetKit

/// The whole app's state. Scans run off the main thread every few seconds and publish here.
@MainActor
@Observable
final class AppModel {
    enum Section: Hashable { case agents, cleanup, workspace(UUID), chat(UUID), terminals, settings }

    var section: Section = .agents
    var workspaces: [Workspace] = WorkspaceStore.load() {
        didSet {
            if let kept = keptEdited(after: oldValue) { workspaces = kept }   // set here, didSet does not run again
            WorkspaceStore.save(workspaces)
        }
    }
    var chats: [ChatSession] = [] { didSet { saveChats() } }
    var terminals: [TerminalTab] = TerminalStore.load() {
        didSet {
            displayTitles = Self.displayTitles(for: terminals)
            scheduleTerminalSave()
        }
    }
    var selectedTerminal: UUID?
    var paused = false
    /// Tabs waiting for "close anyway" because something still runs in them.
    var pendingClose: [UUID] = []

    private(set) var agents: [LiveAgent] = []
    private(set) var servers: [ListeningServer] = []
    private(set) var usage = UsageSnapshot()
    private(set) var system = SystemSnapshot()
    @ObservationIgnored private(set) var parents: [Int32: Int32] = [:]   // process tree, refreshed every poll
    var servicePorts: [UUID: Int] = [:]          // service id -> listening port, per poll
    var serviceMemory: [UUID: UInt64] = [:]      // service id -> memory of its process tree
    var externalServers: [ListeningServer] = []  // listeners Taki did not start
    private(set) var containers: [DockerContainer] = []       // running Docker containers
    private(set) var usageReady = false          // false until the first transcript scan lands
    // Worked out once per poll, read by every list: tabs running something, the tabs' shown
    // names, workspaces with something live in them, and servers no workspace claims.
    var busyTabs: Set<UUID> = []
    private(set) var displayTitles: [UUID: String] = [:]
    var liveWorkspaceIDs: Set<UUID> = []
    var unclaimedServers: [ListeningServer] = []
    private(set) var limits: RateLimits? = LimitsStore.load()
    var facts: [UUID: ProjectFacts] = [:]
    var dismissedFolders = DismissedFolders.load() { didSet { DismissedFolders.save(dismissedFolders) } }
    let runner = ServiceRunner()
    let monitor = ResourceMonitor()
    let cleanup = CleanupModel()

    /// SwiftUI's openWindow, captured by the first view that appears (the menu panel or a window).
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored var terminalSave: DispatchWorkItem?

    /// Seconds between polls, and how many polls apart the heavier scans run.
    static let pollInterval: TimeInterval = 3
    static let usageEvery = 10            // transcripts and memory: every 30 s
    static let cleanupEvery = 100         // the Clean up total: every 5 minutes
    static let dockerEvery = 5            // containers: every 15 s
    static let dockerEveryWhenOff = 20    // every minute when Docker is not answering

    init() {
        displayTitles = Self.displayTitles(for: terminals)
        if Demo.isOn { apply(Demo.snapshot()); return }      // sample data, no scans, no proxy, nothing started
        refreshFacts()
        if UserDefaults.standard.object(forKey: "shortLinks") as? Bool ?? true { LocalProxy.shared.start() }
        restoreChats()
        for ws in workspaces where ws.startAtLaunch { startAll(ws) }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    // MARK: polling

    @ObservationIgnored private var polling = false
    @ObservationIgnored private var dockerMissing = false

    func poll() {
        guard !paused, !polling, !Demo.isOn else { return }   // demo mode shows sample data, never the Mac          // one scan at a time, results never arrive out of order
        polling = true
        tick += 1
        let doUsage = tick % Self.usageEvery == 1
        let doCleanup = tick % Self.cleanupEvery == 1
        let doDocker = tick % (dockerMissing ? Self.dockerEveryWhenOff : Self.dockerEvery) == 1
        let terminalShells = TerminalRegistry.shared.shellPids()
        Task.detached(priority: .utility) {
            var agents = AgentScanner.scan() + AgentScanner.otherAgents()
            let servers = ProcessScanner.listeners()
            let parents = ProcessScanner.parentMap()
            let parentsCopy = parents
            for i in agents.indices {
                agents[i].hostApp = ProcessScanner.hostApp(of: agents[i].pid, parents: parents)
                agents[i].serverCount = servers.filter {
                    ProcessScanner.isDescendant($0.pid, of: agents[i].pid, parents: parents)
                }.count
            }
            let usage = doUsage ? UsageScanner.scan() : nil
            let system = doUsage ? SystemScanner.scan() : nil
            let docker: [DockerContainer]?? = doDocker ? .some(DockerScanner.scan()) : .none
            let shellFolders = terminalShells.compactMapValues { pid -> String? in
                let dir = ProcessScanner.cwd(of: pid)
                return dir.isEmpty ? nil : dir
            }
            await MainActor.run {
                self.polling = false
                self.parents = parentsCopy
                self.agents = agents
                self.servers = servers
                if let usage { self.usage = usage; self.usageReady = true }
                if let system { self.system = system }
                if case let .some(result) = docker {
                    self.containers = result ?? []
                    self.dockerMissing = result == nil       // not installed, off or hung, not "no containers"
                }
                for chat in self.chats where chat.isSuspendable { chat.suspend() }
                self.monitor.sample(workspaces: self.workspaces, runner: self.runner, servers: servers, parents: parentsCopy)
                self.refreshServiceFacts()
                self.adoptOpenProjects()
                self.refreshLiveFacts()
                for (id, dir) in shellFolders where dir != TerminalRegistry.shared.currentFolder(of: id) {
                    TerminalRegistry.shared.moved(id, to: dir)
                    self.terminalMoved(id, to: dir)
                }
                self.refreshTerminalFacts()
                Notifier.shared.check(model: self)
                LocalProxy.shared.update(routes: self.linkRoutes)
                self.publishWidgets()
                if doCleanup {
                    self.cleanup.scan(workspaces: self.workspaces, liveAgentCwds: agents.map(\.cwd), busyFolders: self.busyFolders)
                }
            }
        }
    }

    func refreshFacts() {
        for ws in workspaces { facts[ws.id] = ProjectFacts.read(folder: ws.folder) }
    }

    private(set) var checkingLimits = false

    /// Reads the Claude plan limits on demand: one tiny Haiku request through Claude Code, whose
    /// stream reports the 5-hour and weekly windows. Any Taki chat also updates them for free.
    func checkClaudeLimits() {
        guard !checkingLimits, let claude = ShellEnvironment.which("claude") else { return }
        checkingLimits = true
        Task.detached(priority: .utility) {
            let dir = FileManager.default.temporaryDirectory.appending(path: "taki-limits")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: claude)
            p.arguments = ["-p", "Reply with the single word ok.", "--model", "haiku", "--output-format", "stream-json",
                           "--verbose", "--max-turns", "1", "--setting-sources", "project", "--tools", ""]
            p.currentDirectoryURL = dir
            p.environment = ShellEnvironment.load()
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            var found: RateLimits?
            if (try? p.run()) != nil {
                let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }   // never hang the button
                DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                watchdog.cancel()
                p.waitUntilExit()
                for line in data.split(separator: 0x0A) {
                    if case let .rateLimits(l) = ClaudeStreamParser.parse(line: Data(line)) { found = l }
                }
            }
            let result = found
            await MainActor.run {
                if let result { self.update(limits: result) }
                self.checkingLimits = false
            }
        }
    }

    private func restoreChats() {
        for saved in ChatStore.load() {
            let chat = ChatSession(folder: URL(fileURLWithPath: saved.folder), title: saved.title, resumeID: saved.sessionID,
                                   model: Preferences.chatModel, permissionMode: Preferences.permissionMode)
            chat.onRateLimits = { [weak self] l in self?.update(limits: l) }
            chat.onChange = { [weak self] in self?.saveChats() }
            chat.restore(history: ChatStore.history(sessionID: saved.sessionID, folder: saved.folder))
            chats.append(chat)
        }
    }

    @ObservationIgnored private var lastWidgetSnap: WidgetSnapshot?
    @ObservationIgnored private var lastWidgetReload = Date.distantPast

    /// Writes the widget snapshot; reloads the widgets when it changed, at most once a minute.
    func publishWidgets() {
        guard !Demo.isOn else { return }
        var s = WidgetSnapshot()
        s.servers = servers.map { .init(name: $0.label, port: $0.port, memoryMB: Int($0.memoryBytes / 1_048_576)) }
        s.agents = agents.map { .init(task: $0.task, tool: $0.tool.rawValue, status: $0.status.rawValue,
                                      minutes: Int(Date().timeIntervalSince($0.statusSince) / 60)) }
        s.workspaces = workspaces.map { ws in
            .init(name: ws.name, running: isRunning(ws), memoryMB: Int((monitor.stats[ws.id]?.memory ?? 0) / 1_048_576),
                  agents: agents(in: ws).count)
        }
        s.tokensToday = usage.tokensToday
        s.sessionsPerHour = usage.sessionsPerHour
        s.claudeFiveHour = limits?.fiveHourUsed
        s.claudeWeek = limits?.weekUsed
        s.claudeFiveHourResets = limits?.fiveHourResets
        s.codexWeek = usage.codexWeekUsed
        var compare = s
        compare.updated = lastWidgetSnap?.updated ?? s.updated
        guard compare != lastWidgetSnap || Date().timeIntervalSince(lastWidgetReload) > 300 else { return }
        s.save()
        lastWidgetSnap = s
        if Date().timeIntervalSince(lastWidgetReload) > 60 {
            WidgetCenter.shared.reloadAllTimelines()
            lastWidgetReload = Date()
        }
    }

    func saveChats() {
        ChatStore.save(chats.compactMap { c in
            c.sessionID.map { ChatStore.Saved(folder: c.folder.path, title: c.title, sessionID: $0) }
        })
    }

    func update(limits new: RateLimits) {
        limits = new
        LimitsStore.save(new)
    }

    /// Demo mode: shows the sample data instead of the Mac's own (for screenshots).
    private func apply(_ d: Demo.Snapshot) {
        workspaces = d.workspaces
        facts = d.facts
        agents = d.agents
        servers = d.servers
        externalServers = d.servers
        servicePorts = d.ports
        serviceMemory = d.memory
        containers = d.containers
        usage = d.usage
        usageReady = true
        system = d.system
        limits = d.limits
        runner.showDemo(running: d.running, logs: d.logs)
        monitor.showDemo(d.stats)
        cleanup.showDemo(d.cleanup)
        for chat in d.chats {
            let session = ChatSession(folder: URL(fileURLWithPath: chat.folder), title: chat.title, resumeID: UUID().uuidString)
            session.restore(history: chat.messages)
            chats.append(session)
        }
        refreshLiveFacts()
        section = d.workspaces.first.map { .workspace($0.id) } ?? .agents
    }

    // MARK: derived

    var liveServices: Int { runner.running.count + externalServers.count + containers.count }
    var serversMemory: UInt64 { servers.reduce(0) { $0 + $1.memoryBytes } }

    // MARK: actions

    func newChat(folder: URL, resume: String? = nil, title: String = "New chat") -> ChatSession {
        let chat = ChatSession(folder: folder, title: title, resumeID: resume,
                               model: Preferences.chatModel, permissionMode: Preferences.permissionMode)
        chat.onRateLimits = { [weak self] l in self?.update(limits: l) }
        chat.onChange = { [weak self] in self?.saveChats() }
        chats.append(chat)
        chat.start()
        section = .chat(chat.id)
        return chat
    }

    /// The folder a new chat or terminal opens in: the selected workspace, else the last chat's.
    var defaultFolder: String {
        if case let .workspace(id) = section, let ws = workspaces.first(where: { $0.id == id }) { return ws.folder }
        return chats.last?.folder.path ?? workspaces.first?.folder ?? NSHomeDirectory()
    }

    func newChatInLastFolder() {
        _ = newChat(folder: URL(fileURLWithPath: defaultFolder))
    }

    /// The same conversation in Claude Code itself, in a new Taki tab. The chat gives its Claude
    /// process back first, so two processes never write to one session.
    func continueInClaudeCode(_ chat: ChatSession) {
        guard let sid = chat.sessionID, AgentScanner.isSessionID(sid) else { return }
        chat.suspend()
        newTerminal(folder: chat.folder.path, command: "claude --resume \(sid)", title: chat.title)
    }

    func closeChat(_ chat: ChatSession) {
        chat.stop()
        chats.removeAll { $0.id == chat.id }
        if section == .chat(chat.id) { section = .agents }
    }

    /// Stop a live agent found on the Mac (asks the process to end, like Ctrl-C).
    /// Only a real process: kill() with 0 or a negative pid would signal a whole process group,
    /// Taki's own included.
    func stopAgent(_ a: LiveAgent) {
        guard a.pid > 1, !Demo.isOn else { return }
        kill(a.pid, SIGINT)
    }

    /// Open: go to where the agent is running. Its Taki chat, its Taki terminal tab, or the exact
    /// Terminal or iTerm tab it lives in. Anything else brings its app to the front.
    func open(_ a: LiveAgent) {
        if let chat = chats.first(where: { $0.sessionID == a.id }) { section = .chat(chat.id); return }
        if let tab = TerminalRegistry.shared.tab(containing: a.pid, parents: parents) {
            selectedTerminal = tab
            section = .terminals
            openMainWindow?()
            return
        }
        guard a.pid > 1 else { return }
        HostFocus.focus(pid: a.pid, hostApp: a.hostApp)   // its exact tab, or at least its app
    }

    /// Continue in Claude Code: the session resumed in a new Taki tab. If it is still running
    /// elsewhere, Claude Code itself starts a copy and says so.
    func continueInTaki(_ a: LiveAgent) {
        guard AgentScanner.isSessionID(a.id) else { return }
        newTerminal(folder: a.cwd, command: "claude --resume \(a.id)", title: a.task)
        openMainWindow?()
    }

}

/// The last Claude plan limits seen, so the menu bar shows them before the next chat reports.
enum LimitsStore {
    static func load() -> RateLimits? {
        guard let d = UserDefaults.standard.data(forKey: "claudeLimits") else { return nil }
        return try? JSONDecoder().decode(RateLimits.self, from: d)
    }

    static func save(_ l: RateLimits) {
        if let d = try? JSONEncoder().encode(l) { UserDefaults.standard.set(d, forKey: "claudeLimits") }
    }
}

enum Preferences {
    static var chatModel: String { UserDefaults.standard.string(forKey: "chatModel") ?? "" }
    static var permissionMode: String { UserDefaults.standard.string(forKey: "permissionMode") ?? "" }
    static var editorBundleID: String { UserDefaults.standard.string(forKey: "editor") ?? "com.apple.finder" }
}

enum EditorChoice: String, CaseIterable {
    case cursor = "com.todesktop.230313mzl4w4u92", vscode = "com.microsoft.VSCode", zed = "dev.zed.Zed",
         xcode = "com.apple.dt.Xcode", finder = "com.apple.finder"
    var name: String {
        switch self {
        case .cursor: "Cursor"
        case .vscode: "VS Code"
        case .zed: "Zed"
        case .xcode: "Xcode"
        case .finder: "Finder"
        }
    }
    static var current: EditorChoice { EditorChoice(rawValue: Preferences.editorBundleID) ?? .cursor }
}
