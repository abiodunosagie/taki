import SwiftUI

/// The menu bar panel: header, three tiles (Running, Agents,
/// Clean up), AI usage (Codex ring, all-agent tokens, Claude ring), the last 24 hours, the live
/// tree of workspaces and their agents, and a filter field.
struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let openMain: () -> Void
    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    static let width: CGFloat = 400

    var body: some View {
        VStack(spacing: 8) {
            header
            HStack(spacing: 10) {
                Tile(title: "Running", tag: "Live", selected: false, action: { open(.agents) }) {
                    HStack(alignment: .lastTextBaseline) {
                        Text("\(model.liveServices)").font(.system(size: 22, weight: .medium)).monospacedDigit().lineLimit(1).fixedSize()
                        Spacer()
                        Text(Format.bytesText(model.serversMemory)).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1).fixedSize()
                    }
                }
                Tile(title: "Agents", tag: nil, selected: true, action: { open(.agents) }) {
                    HStack(alignment: .lastTextBaseline) {
                        Text("\(model.agents.count)").font(.system(size: 22, weight: .medium)).monospacedDigit().lineLimit(1).fixedSize()
                        Spacer()
                        Sparkline(values: model.usage.sessionsPerHour.suffix(10).map(Double.init), highlight: Theme.busy, height: 18)
                    }
                }
                Tile(title: "Clean up", tag: nil, selected: false, action: { open(.cleanup) }) {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(Format.bytes(model.cleanup.totalBytes).0).font(.system(size: 22, weight: .medium)).monospacedDigit().lineLimit(1).fixedSize()
                        Text(Format.bytes(model.cleanup.totalBytes).1).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize()
                        Spacer()
                        Capsule().fill(Theme.busy.opacity(0.85)).frame(maxWidth: 44).frame(height: 4).padding(.bottom, 6)
                    }
                }
            }
            usageCard
            dayCard
            liveCard
            filterField
        }
        .padding(10)
        .frame(width: Self.width)
        .foregroundStyle(Theme.primary)
        // A solid panel surface (the popover's own blur lets the desktop wash the text out).
        .background(LinearGradient(colors: [Theme.windowTop, Theme.windowBottom], startPoint: .top, endPoint: .bottom))
        .onDisappear { filter = "" }
        .onAppear { if model.openMainWindow == nil { model.openMainWindow = { openWindow(id: "main") } } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "water.waves").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.link)
            Text("Taki").font(.system(size: 15, weight: .semibold))
            Spacer()
            iconButton(model.paused ? "play.fill" : "pause.fill", help: model.paused ? "Resume updates" : "Pause updates") {
                model.paused.toggle()
            }
            iconButton("gearshape", help: "Settings") { open(.settings) }
            iconButton("power", help: "Quit Taki") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 6).padding(.top, 2)
    }

    private var usageCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("AI usage").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                HStack(alignment: .center, spacing: 0) {
                    HStack(spacing: 9) {
                        Ring(value: model.usage.codexWeekUsed, color: Theme.codexBlue, size: 48, track: Theme.ringTrack) {
                            Image(systemName: "apple.terminal.fill").font(.system(size: 13)).foregroundStyle(.white)
                        }
                        stack(top: "Codex", main: model.usage.codexWeekUsed.map { "\(Int($0 * 100))%" } ?? "-",
                              bottom: "Week", extra: model.usage.codexWeekAsOf.map { "as of \($0.formatted(.dateTime.weekday(.abbreviated)))" })
                    }
                    Spacer(minLength: 8)
                    HStack(alignment: .center, spacing: 9) {
                        Sparkline(values: model.usage.tokensPerHour.suffix(7).map(Double.init), highlight: Theme.codexBlue, height: 44, barWidth: 4.5)
                        stack(top: "All agents", main: model.usageReady ? Format.tokens(model.usage.tokensToday) : "...",
                              bottom: "Today", extra: "tokens")
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 9) {
                        Ring(value: model.limits?.fiveHourUsed, color: Theme.claude, size: 48, track: Theme.ringTrack) {
                            Image("logo-claude").resizable().scaledToFit().frame(width: 18, height: 18).foregroundStyle(Theme.claude)
                        }
                        if let l = model.limits {
                            stack(top: "Claude", main: l.fiveHourUsed.map { "\(Int($0 * 100))%" } ?? "-",
                                  bottom: "5 hours", extra: l.weekUsed.map { "week \(Int($0 * 100))%" })
                        } else {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Claude").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                Text("Limits").font(.system(size: 13, weight: .medium))
                                LinkButton(model.checkingLimits ? "Checking..." : "Connect...") { model.checkClaudeLimits() }
                                    .help("Reads your plan limits with one tiny Haiku request through Claude Code")
                            }
                            .fixedSize()
                        }
                    }
                }
            }
        }
    }

    private var dayCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Last 24 hours").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text(Format.plural(model.usage.sessions24h, "session")).font(.system(size: 13, weight: .medium))
                }
                ActivityBars(values: model.usage.sessionsPerHour.map(Double.init), compact: true).frame(height: 74)
            }
        }
    }

    private var liveCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("Live").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                    Text("\(filteredAgents.count)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(groups, id: \.0) { folder, agents in
                            HStack(spacing: 12) {
                                WorkspaceBadge(symbol: "folder", name: (folder as NSString).lastPathComponent, logo: logoFor(folder), size: 22)
                                Text((folder as NSString).lastPathComponent).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text((folder as NSString).abbreviatingWithTildeInPath).font(.system(size: 12))
                                    .foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Text(Format.plural(agents.count, "agent")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            }
                            ForEach(agents) { a in agentRow(a) }
                        }
                        if groups.isEmpty {
                            Text(filter.isEmpty ? "No agents running." : "Nothing matches.")
                                .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                        }
                        let servers = filteredServers
                        if !servers.isEmpty {
                            Divider().opacity(0.4)
                            ForEach(servers) { s in
                                HStack(spacing: 10) {
                                    StatusDot(color: Theme.live)
                                    Text(s.label).font(.system(size: 13)).lineLimit(1)
                                    Spacer()
                                    Text(Format.bytesText(s.memoryBytes)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                    Button { if let u = URL(string: "http://localhost:\(s.port)") { NSWorkspace.shared.open(u) } } label: {
                                        Text(verbatim: ":\(s.port)").font(.system(size: 13, weight: .medium, design: .monospaced))
                                            .foregroundStyle(Theme.link)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 190)
            }
        }
    }

    private func agentRow(_ a: LiveAgent) -> some View {
        HStack(spacing: 12) {
            AgentGlyph(tool: a.tool, size: 30, framed: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.task).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(a.subtitle(style: .tree)).font(.system(size: 12))
                    .foregroundStyle(a.status == .working ? Theme.busy : Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            AgentButtons(agent: a, size: 26, afterOpen: openMain)
        }
        .contextMenu { AgentMenu(agent: a) }
        .padding(.leading, 32)
        .overlay(alignment: .topLeading) {
            // The tree line from the workspace badge down to each agent.
            Path { p in
                p.move(to: CGPoint(x: 11, y: -10)); p.addLine(to: CGPoint(x: 11, y: 15)); p.addLine(to: CGPoint(x: 27, y: 15))
            }
            .stroke(Theme.tertiary, lineWidth: 1)
        }
    }

    private var filterField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
            TextField("Filter by name or port...", text: $filter).textFieldStyle(.plain).font(.system(size: 13)).focused($filterFocused)
            Text("⌘K").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.tertiary))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .tileSurface(radius: 12)
        .background { Button("") { filterFocused = true }.keyboardShortcut("k").opacity(0) }
    }

    // MARK: helpers

    private var filteredAgents: [LiveAgent] {
        model.agents.filter {
            filter.isEmpty || $0.task.localizedCaseInsensitiveContains(filter) || $0.cwd.localizedCaseInsensitiveContains(filter)
        }
    }

    private var filteredServers: [ListeningServer] {
        model.servers.filter { filter.isEmpty || String($0.port).contains(filter) || $0.label.localizedCaseInsensitiveContains(filter) }
    }

    private var groups: [(String, [LiveAgent])] {
        Dictionary(grouping: filteredAgents) { $0.project ?? $0.cwd }.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    private func open(_ s: AppModel.Section) { model.section = s; openMain() }

    private func logoFor(_ folder: String) -> String? {
        model.workspaces.first { $0.folder == folder }.flatMap { model.logo(of: $0) }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 22, height: 22) }
            .buttonStyle(.plain).help(help)
    }

    private func stack(top: String, main: String, bottom: String, extra: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(top).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Text(main).font(.system(size: 22, weight: .bold)).monospacedDigit()
            Text(bottom).font(.system(size: 12, weight: .medium))
            if let extra { Text(extra).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// A panel section: a flat tile, slightly lighter than the panel.
struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tileSurface(radius: 14)
    }
}

/// One of the three top tiles; the selected one is lit.
struct Tile<Content: View>: View {
    let title: String
    let tag: String?
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(selected ? Theme.primary : Theme.secondary)
                    Spacer()
                    if let tag { Text(tag).font(.system(size: 11)).foregroundStyle(Theme.live) }
                }
                content
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tileSurface(radius: 14, raised: selected)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(selected ? Theme.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.primary)
    }
}
