import AppKit
import Foundation

/// Workspaces: which agents, servers and containers belong to each, the ones Taki finds open on
/// the Mac by itself, and the owner's actions on them.
extension AppModel {
    /// How long a found workspace stays after nothing runs in it.
    static let autoWorkspaceLifetime: TimeInterval = 86_400
    /// A live found workspace records that it is live at most this often (each record rewrites the file).
    static let lastActiveStep: TimeInterval = 60

    /// Something runs in a workspace when it was started inside the folder, or works on a
    /// repository inside it. A server or agent in a sub-package of a monorepo belongs to the
    /// sub-package's workspace even though its repository root is the monorepo.
    nonisolated static func belongs(cwd: String, project: String?, to ws: Workspace) -> Bool {
        (!cwd.isEmpty && ws.contains(path: cwd)) || (project.map { ws.contains(path: $0) } ?? false)
    }

    func agents(in ws: Workspace) -> [LiveAgent] {
        agents.filter { Self.belongs(cwd: $0.cwd, project: $0.project, to: ws) }
    }

    /// Dev servers running in a workspace that Taki did not start (a terminal, an agent).
    func externalServers(in ws: Workspace) -> [ListeningServer] {
        externalServers.filter { Self.belongs(cwd: $0.cwd, project: $0.project, to: ws) }
    }

    /// Containers that belong to a workspace (their compose folder is inside it).
    func containers(in ws: Workspace) -> [DockerContainer] {
        containers.filter { c in c.workingDir.map { ws.contains(path: $0) } ?? false }
    }

    func isRunning(_ ws: Workspace) -> Bool { ws.services.contains { runner.isRunning($0) } }

    /// Something is running in it: its own services, a server started elsewhere, a container, an
    /// agent. The outside part is worked out once per poll.
    func isLive(_ ws: Workspace) -> Bool { isRunning(ws) || liveWorkspaceIDs.contains(ws.id) }

    private func isLiveNow(_ ws: Workspace) -> Bool {
        isRunning(ws) || !externalServers(in: ws).isEmpty || !containers(in: ws).isEmpty || !agents(in: ws).isEmpty
    }

    /// Workspaces with a running service: their build caches are in use.
    var busyFolders: Set<String> { Set(workspaces.filter { isRunning($0) }.map(\.folder)) }

    /// The workspace's badge: the owner's choice, else the framework's mark.
    func logo(of ws: Workspace) -> String? {
        if let o = ws.iconOverride { return o.hasPrefix("logo:") ? String(o.dropFirst(5)) : nil }
        return facts[ws.id]?.logo
    }

    /// link name -> the first running service port of each workspace, for the localhost proxy.
    var linkRoutes: [String: Int] {
        var out: [String: Int] = [:]
        for ws in workspaces {
            if let port = ws.services.lazy.compactMap({ self.servicePorts[$0.id] }).first { out[ws.linkName] = port }
        }
        return out
    }

    /// Ports, memory and the "not ours" server list, from this poll's process tree.
    func refreshServiceFacts() {
        var ours = Set<Int32>(), ports: [UUID: Int] = [:], mem: [UUID: UInt64] = [:]
        for ws in workspaces {
            for s in ws.services {
                guard let run = runner.running[s.id] else { continue }
                let tree = Set([run.pid] + ProcessScanner.descendants(of: run.pid, parents: parents))
                ours.formUnion(tree)
                ports[s.id] = s.port ?? servers.first { tree.contains($0.pid) }?.port
                mem[s.id] = tree.reduce(0) { $0 + ProcessScanner.memory(of: $1) }
            }
        }
        servicePorts = ports
        serviceMemory = mem
        externalServers = servers.filter { !ours.contains($0.pid) }
    }

    /// Facts the sidebar and the menu read many times per frame, worked out once per poll.
    func refreshLiveFacts() {
        liveWorkspaceIDs = Set(workspaces.filter(isLiveNow).map(\.id))
        unclaimedServers = externalServers.filter { s in !workspaces.contains { Self.belongs(cwd: s.cwd, project: s.project, to: $0) } }
    }

    /// Everything open on the Mac becomes a workspace by itself: the repository each live agent is
    /// working in, the repository of each running dev server, and each Docker compose project folder.
    /// Found ones are marked `auto` and drop off a day after nothing runs in them; editing one keeps
    /// it. A folder the owner removed is not found again, and neither is a repository that already
    /// holds a workspace further down (a monorepo whose package is a workspace).
    func adoptOpenProjects() {
        struct Item { let cwd: String; let project: String? }
        var items = agents.map { Item(cwd: $0.cwd, project: $0.project) }
        items += externalServers.map { Item(cwd: $0.cwd, project: $0.project) }
        items += containers.compactMap { c in c.workingDir.map { Item(cwd: $0, project: ProjectRoot.of($0) ?? $0) } }
        items.sort { ($0.project ?? "").count < ($1.project ?? "").count }   // outer repositories first, every poll the same

        let now = Date()
        var list = workspaces
        var changed = false
        for item in items {
            if let i = list.firstIndex(where: { Self.belongs(cwd: item.cwd, project: item.project, to: $0) }) {
                if list[i].auto == true, now.timeIntervalSince(list[i].lastActive ?? .distantPast) > Self.lastActiveStep {
                    list[i].lastActive = now
                    changed = true
                }
                continue
            }
            guard let folder = item.project, Workspace.isAdoptable(folder), !dismissedFolders.contains(folder),
                  !list.contains(where: { $0.folder.hasPrefix(folder + "/") }) else { continue }
            let name = (folder as NSString).lastPathComponent
            list.append(Workspace(name: name, folder: folder, services: [], linkName: WorkspaceStore.linkName(for: name),
                                  auto: true, lastActive: now))
            facts[list[list.count - 1].id] = ProjectFacts.read(folder: folder)
            changed = true
        }
        let stale = now.addingTimeInterval(-Self.autoWorkspaceLifetime)
        let before = list.count
        list.removeAll { $0.auto == true && ($0.lastActive ?? .distantPast) < stale && !isRunning($0) }
        if changed || list.count != before { workspaces = list }
    }

    /// Called from the `workspaces` observer: a found workspace the owner changed in any way (name,
    /// icon, a service, a variable, the link) becomes his and is kept. Nil when nothing changes.
    func keptEdited(after old: [Workspace]) -> [Workspace]? {
        var list = workspaces
        var kept = false
        for i in list.indices where list[i].auto == true {
            if let before = old.first(where: { $0.id == list[i].id }), before.settings != list[i].settings {
                list[i].auto = nil
                kept = true
            }
        }
        return kept ? list : nil
    }

    // MARK: actions

    @discardableResult
    func addWorkspace(folder: URL) -> Workspace {
        dismissedFolders.remove(folder.path)
        if let i = workspaces.firstIndex(where: { $0.folder == folder.path }) {
            workspaces[i].auto = nil                     // added by hand: it stays
            return workspaces[i]
        }
        let f = ProjectFacts.read(folder: folder.path)
        let name = folder.lastPathComponent
        let ws = Workspace(name: name, folder: folder.path, services: f.suggested,
                           linkName: WorkspaceStore.linkName(for: name))
        workspaces.append(ws)
        facts[ws.id] = f
        return ws
    }

    /// Removes it from Taki and remembers the folder, so a project still open there does not
    /// bring it straight back. Adding the folder again by hand clears that.
    func removeWorkspace(_ ws: Workspace) {
        for s in ws.services { runner.stop(s) }
        Keychain.deleteAll(workspace: ws.id)
        dismissedFolders.insert(ws.folder)
        workspaces.removeAll { $0.id == ws.id }
        if section == .workspace(ws.id) { section = .agents }
    }

    func startAll(_ ws: Workspace) { for s in ws.services { runner.start(s, in: ws) } }
    func stopAll(_ ws: Workspace) { for s in ws.services { runner.stop(s) } }

    /// Open in Claude: Claude Code in a new tab, in the workspace folder.
    func openInClaude(_ ws: Workspace) {
        newTerminal(.claude, folder: ws.folder, name: ws.name)
    }

    func openInEditor(_ ws: Workspace) {
        let url = ws.folderURL
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Preferences.editorBundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Folders the owner removed from Taki: never found again by themselves.
enum DismissedFolders {
    private static let key = "dismissedFolders"
    static func load() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    static func save(_ s: Set<String>) { UserDefaults.standard.set(Array(s).sorted(), forKey: key) }
}
