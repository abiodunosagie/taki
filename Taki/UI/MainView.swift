import SwiftUI

/// The window: a slate background and a floating sidebar panel inset from the edges. The window's
/// own buttons (the system's, not drawn by Taki) sit inside the panel with room around them,
/// placed by `WindowChrome` the way Finder and Chrome lower theirs.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    static let panelInset: CGFloat = 8

    var body: some View {
        window
    }

    private var window: some View {
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
        case .terminals: TerminalsView()
        case .settings: SettingsView()
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

                    if !model.terminals.isEmpty {
                        SectionHeader(title: "Terminals", open: $showTerminals, trailing: {
                            NewTerminalMenu { Image(systemName: "plus").font(.system(size: 13, weight: .medium)) }
                                .help("New tab: pick a folder and a shell or an agent")
                                .accessibilityLabel("New terminal tab")
                        })
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
                }
            }
            // The scroll area starts below the window buttons, so rows never slide up behind them;
            // the soft edge fades a row out as it reaches the top instead of cutting it hard.
            .scrollEdgeEffectStyle(.soft, for: .top)
            .padding(.top, WindowChrome.buttonsBottom - MainView.panelInset + WindowChrome.rowsGap)
            UpgradeCard().padding(.bottom, 8)
            row(.settings, icon: "gearshape", title: "Settings")
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .font(.system(size: 15))
        .overlay(alignment: .topTrailing) { editionName }
    }

    /// "Taki Pro" (or "Taki") beside the window buttons, so the window says which edition it is.
    private var editionName: some View {
        Text(Edition.name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.secondary)
            .frame(height: WindowChrome.buttonHalfHeight * 2)
            .padding(.top, WindowChrome.bandHeight / 2 - MainView.panelInset - WindowChrome.buttonHalfHeight)
            .padding(.trailing, 16)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isHeader)
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

}


struct SectionHeader<Trailing: View>: View {
    let title: String
    @Binding var open: Bool
    let trailing: Trailing
    @State private var hover = false

    init(title: String, open: Binding<Bool>, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self._open = open
        self.trailing = trailing()
    }

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
            trailing
        }
        .sidebarHeader()
        .onHover { hover = $0 }
    }
}

extension SectionHeader where Trailing == HeaderAddButton {
    /// A header whose + runs one action (or shows no + when `add` is nil).
    init(title: String, open: Binding<Bool>, add: (() -> Void)?) {
        self.init(title: title, open: open, trailing: { HeaderAddButton(add: add) })
    }
}

/// The plain + on a sidebar header that runs one action.
struct HeaderAddButton: View {
    let add: (() -> Void)?
    var body: some View {
        if let add {
            Button(action: add) { Image(systemName: "plus").font(.system(size: 13, weight: .medium)) }
                .buttonStyle(.plain).help("Add")
        }
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
