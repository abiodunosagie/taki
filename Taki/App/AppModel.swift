import AppKit
import Foundation
import Observation

/// The whole app's state. Scans run off the main thread every few seconds and publish here.
@MainActor
@Observable
final class AppModel {
    enum Section: Hashable { case agents, terminals, settings }

    var section: Section = .agents
    var terminals: [TerminalTab] = TerminalStore.load() {
        didSet {
            displayTitles = Self.displayTitles(for: terminals)
            scheduleTerminalSave()
        }
    }
    var selectedTerminal: UUID?
    /// Set when the free edition's tab limit stops a new tab; the Terminals screen shows a note.
    var tabLimitReached = false
    var paused = false
    /// Tabs waiting for "close anyway" because something still runs in them.
    var pendingClose: [UUID] = []

    var agents: [LiveAgent] = []
    var servers: [ListeningServer] = []
    var usage = UsageSnapshot()
    var system = SystemSnapshot()
    @ObservationIgnored private(set) var parents: [Int32: Int32] = [:]   // process tree, refreshed every poll
    var externalServers: [ListeningServer] = []  // listeners Taki did not start
    var usageReady = false          // false until the first transcript scan lands
    // Worked out once per poll, read by every list: tabs running something, the tabs' shown
    // names, workspaces with something live in them, and servers no workspace claims.
    var busyTabs: Set<UUID> = []
    private(set) var displayTitles: [UUID: String] = [:]
    var unclaimedServers: [ListeningServer] = []
    var limits: RateLimits? = LimitsStore.load()

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
        guard !TestHost.isActive else { return }            // a test host starts nothing
        if Demo.isOn { apply(Demo.snapshot()); return }      // sample data, no scans, no proxy, nothing started
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    // MARK: polling

    @ObservationIgnored private var polling = false

    func poll() {
        // One scan at a time, so results never arrive out of order; demo mode never scans the Mac.
        guard !paused, !polling, !Demo.isOn else { return }
        polling = true
        tick += 1
        let doUsage = tick % Self.usageEvery == 1
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
                self.externalServers = servers
                self.unclaimedServers = servers
                for (id, dir) in shellFolders where dir != TerminalRegistry.shared.currentFolder(of: id) {
                    TerminalRegistry.shared.moved(id, to: dir)
                    self.terminalMoved(id, to: dir)
                }
                self.refreshTerminalFacts()
            }
        }
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

    func update(limits new: RateLimits) {
        limits = new
        LimitsStore.save(new)
    }

    // MARK: derived

    var liveServices: Int { externalServers.count }
    var serversMemory: UInt64 { servers.reduce(0) { $0 + $1.memoryBytes } }

    // MARK: actions

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

/// The last Claude plan limits seen, so they show at launch before the next reading.
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
