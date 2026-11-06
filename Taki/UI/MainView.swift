import SwiftUI

/// The window: a slate background and a floating sidebar panel inset from the edges. The window's
/// own buttons (the system's, not drawn by Taki) sit inside the panel with room around them,
/// placed by `WindowChrome` the way Finder and Chrome lower theirs.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    static let panelInset: CGFloat = 8

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 252)
                .sidebarPanel()
                .padding(Self.panelInset)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(Theme.primary)
        .background(LinearGradient(colors: [Theme.windowTop, Theme.windowBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
        .ignoresSafeArea()
        .background(WindowChrome())
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .agents: AgentsView()
        case .cleanup: CleanupView()
        case .terminals: TerminalsView()
        case .settings: SettingsView()
        case let .workspace(id):
            if model.workspaces.contains(where: { $0.id == id }) { WorkspaceView(workspaceID: id) } else { AgentsView() }
        case let .chat(id):
            if let chat = model.chats.first(where: { $0.id == id }) { ChatView(chat: chat) } else { AgentsView() }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sidebar.chats") private var showChats = true
    @AppStorage("sidebar.terminals") private var showTerminals = true
    @AppStorage("sidebar.workspaces") private var showWorkspaces = true
    @AppStorage("sidebar.servers") private var showServers = true
    @AppStorage("sidebar.docker") private var showDocker = true
    @State private var search = ""

    static let maxTabsListed = 6         // the rest are one click away in the Terminals switcher
    static let filterFrom = 10           // a filter field appears once this many rows are listed

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    row(.agents, icon: "sparkle", title: "Agents",
                        trailing: model.agents.isEmpty ? nil : "\(model.agents.count) live", trailingColor: Theme.busy)
                    row(.terminals, icon: "terminal", title: "Terminals",
                        trailing: model.terminals.isEmpty ? nil : "\(model.terminals.count)")
                    row(.cleanup, icon: "shippingbox", title: "Clean up",
                        trailing: model.cleanup.totalBytes > 0 ? Format.bytesText(model.cleanup.totalBytes) : nil)

                    if !model.chats.isEmpty {
                        header("Chats", open: $showChats) { model.newChatInLastFolder() }
                        if showChats { ForEach(model.chats) { chat in
                            row(.chat(chat.id), icon: "bubble.left", title: chat.title,
                                dot: chat.state == .working ? Theme.busy : chat.state == .waiting ? Theme.link : nil)
                                .contextMenu {
                                    Button("Continue in Claude Code") { model.continueInClaudeCode(chat) }
                                        .disabled(chat.sessionID == nil)
                                    Button("Close chat", role: .destructive) { model.closeChat(chat) }
                                }
                        } }
                    }

                    if !model.terminals.isEmpty {
                        header("Terminals", open: $showTerminals) { model.newTerminalTab() }
                        if showTerminals { ForEach(model.terminals.prefix(Self.maxTabsListed)) { tab in
                            Button {
                                model.selectedTerminal = tab.id
                                model.section = .terminals
                            } label: {
                                HStack(spacing: 12) {
                                    TabGlyph(tab: tab, size: 14).frame(width: 24)
                                    Text(model.displayTitle(tab)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if model.terminalIsBusy(tab.id) { StatusDot(color: Theme.busy) }
                                }
                                .sidebarRow(selected: model.section == .terminals && model.selectedTerminal == tab.id)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Close terminal", role: .destructive) { model.requestClose(tab.id) } }
                        }
                        if model.terminals.count > Self.maxTabsListed {
                            Button { model.section = .terminals } label: {
                                Text("\(model.terminals.count - Self.maxTabsListed) more in Terminals")
                                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                                    .padding(.leading, 48).padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        } }
                    }

                    header("Workspaces", open: $showWorkspaces) { addWorkspaces() }
                    if showWorkspaces && model.workspaces.count >= Self.filterFrom {
                        FieldBox {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                                TextField("Filter", text: $search).textFieldStyle(.plain).font(.system(size: 13))
                            }
                        }
                        .padding(.horizontal, 4).padding(.bottom, 4)
                    }
                    if showWorkspaces { ForEach(sortedWorkspaces) { ws in
                        Button { model.section = .workspace(ws.id) } label: {
                            HStack(spacing: 12) {
                                WorkspaceBadge(symbol: ws.iconOverride ?? model.facts[ws.id]?.symbol ?? "folder", name: ws.name,
                                               logo: model.logo(of: ws))
                                Text(ws.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if model.isLive(ws) { StatusDot(color: Theme.live) }
                            }
                            .sidebarRow(selected: model.section == .workspace(ws.id))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Start all") { model.startAll(ws) }
                            Button("Stop all") { model.stopAll(ws) }
                            Button("New chat here") { _ = model.newChat(folder: ws.folderURL) }
                            Button("New terminal here") { model.newTerminal(.shell, folder: ws.folder, name: ws.name) }
                        }
                    } }
                    if model.workspaces.isEmpty && showWorkspaces {
                        Text("Projects with an agent, server or container running appear here by themselves.")
                            .font(.system(size: 13)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12).padding(.vertical, 4)
                    }

                    // Servers that belong to no workspace (the rest show inside their workspace).
                    let ext = model.unclaimedServers
                    if !ext.isEmpty {
                        header("Servers", open: $showServers, add: nil)
                        if showServers { ForEach(ext) { s in
                            Button { open(port: s.port) } label: {
                                HStack(spacing: 12) {
                                    WorkspaceBadge(symbol: "bolt.fill", name: s.command, logo: Brand.logo(forImage: s.command))
                                    Text(s.label).lineLimit(1)
                                    Spacer()
                                    Text(verbatim: ":\(s.port)").font(.system(size: 14).monospacedDigit()).foregroundStyle(Theme.secondary)
                                }
                                .sidebarRow(selected: false)
                            }
                            .buttonStyle(.plain)
                            .help("Open http://localhost:\(s.port)")
                        } }
                    }
                    if !model.containers.isEmpty {
                        header("Docker", open: $showDocker, add: nil)
                        if showDocker {
                            let groups = Dictionary(grouping: model.containers) { $0.project ?? $0.name }
                            ForEach(groups.keys.sorted(), id: \.self) { project in
                                let items = groups[project] ?? []
                                DockerProjectRow(project: project, containers: items)
                            }
                        }
                    }
                }
                .padding(.top, WindowChrome.buttonsBottom - MainView.panelInset + WindowChrome.rowsGap)   // clears the window buttons
            }
            row(.settings, icon: "gearshape", title: "Settings")
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .font(.system(size: 15))
    }

    /// Live workspaces first, then by name; the filter narrows by name or folder.
    private var sortedWorkspaces: [Workspace] {
        model.workspaces
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.folder.localizedCaseInsensitiveContains(search) }
            .sorted { a, b in
                let la = model.isLive(a), lb = model.isLive(b)
                return la != lb ? la : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    private func open(port: Int) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }

    private func row(_ s: AppModel.Section, icon: String, title: String, trailing: String? = nil,
                     trailingColor: Color = Theme.secondary, dot: Color? = nil) -> some View {
        Button { model.section = s } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.secondary).frame(width: 24)
                Text(title).lineLimit(1)
                Spacer()
                if let dot { StatusDot(color: dot) }
                if let trailing { Text(trailing).font(.system(size: 14)).foregroundStyle(trailingColor) }
            }
            .sidebarRow(selected: model.section == s)
        }
        .buttonStyle(.plain)
    }

    /// A section title that folds its rows away (the chevron appears on hover, like Finder).
    private func header(_ title: String, open: Binding<Bool>, add: (() -> Void)?) -> some View {
        SectionHeader(title: title, open: open, add: add)
    }

    private func addWorkspaces() {
        for url in FolderPicker.choose(prompt: "Add workspace", multiple: true) {
            let ws = model.addWorkspace(folder: url)
            model.section = .workspace(ws.id)
        }
    }
}

/// A Docker compose project in the sidebar: its containers fold out under it.
struct DockerProjectRow: View {
    let project: String
    let containers: [DockerContainer]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { withAnimation(.easeOut(duration: 0.18)) { open.toggle() } } label: {
                HStack(spacing: 12) {
                    WorkspaceBadge(symbol: "shippingbox.fill", name: project, logo: "docker")
                    Text(project).lineLimit(1)
                    Spacer()
                    Text("\(containers.count)").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .sidebarRow(selected: false)
            }
            .buttonStyle(.plain)
            if open {
                ForEach(containers) { c in
                    HStack(spacing: 10) {
                        StatusDot(color: c.healthy ? Theme.live : Theme.danger)
                        Text(c.shortName).font(.system(size: 14)).lineLimit(1)
                        Spacer()
                        if let p = c.ports.first {
                            Button { if let u = URL(string: "http://localhost:\(p)") { NSWorkspace.shared.open(u) } } label: {
                                Text(verbatim: ":\(p)").font(.system(size: 13).monospacedDigit()).foregroundStyle(Theme.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 30).padding(.trailing, 12).padding(.vertical, 4)
                    .help("\(c.image) · \(c.status)")
                }
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    @Binding var open: Bool
    let add: (() -> Void)?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.18)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(title)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(open ? 0 : -90))
                        .opacity(hover ? 1 : 0.7)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if let add {
                Button(action: add) { Image(systemName: "plus").font(.system(size: 13, weight: .medium)) }
                    .buttonStyle(.plain).help("Add")
            }
        }
        .sidebarHeader()
        .onHover { hover = $0 }
    }
}

extension View {
    func sidebarRow(selected: Bool) -> some View {
        padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(selected ? Theme.selection : .clear, in: .rect(cornerRadius: 10, style: .continuous))
    }

    func sidebarHeader() -> some View {
        font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 6)
    }
}
