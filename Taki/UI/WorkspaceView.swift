import SwiftUI

/// The workspace dashboard: a header with the editor, refresh and
/// Running switch; a left column of stat tiles, services, agents and logs; a right column of
/// workspace settings with "Remove workspace..." pinned to the bottom.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    let workspaceID: UUID

    var body: some View {
        if let ws = model.workspaces.first(where: { $0.id == workspaceID }) {
            VStack(spacing: 14) {
                header(ws)
                HStack(alignment: .top, spacing: Theme.gutter) {
                    VStack(spacing: Theme.gutter) {
                        StatTiles(ws: ws)
                            .frame(height: 124)
                        HStack(alignment: .top, spacing: Theme.gutter) {
                            ServicesCard(workspaceID: ws.id)
                            WorkspaceAgentsCard(ws: ws)
                        }
                        .frame(height: 204)
                        LogsCard(workspaceID: ws.id)
                    }
                    WorkspaceSettingsColumn(workspaceID: ws.id)
                        .frame(width: settingsWidth)
                }
            }
            .screenPadding()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
    }

    @State private var width: CGFloat = 1100
    /// The settings column gives up width first on small windows (340 down to 290).
    private var settingsWidth: CGFloat { min(340, max(290, width * 0.27)) }

    private func header(_ ws: Workspace) -> some View {
        let facts = model.facts[ws.id] ?? ProjectFacts()
        let running = model.isRunning(ws)
        return HStack(spacing: 14) {
            WorkspaceBadge(symbol: ws.iconOverride ?? facts.symbol, name: ws.name, logo: model.logo(of: ws), size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(ws.name).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                Text([ws.displayFolder, facts.framework, facts.branch].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                Button("Claude Code in a new tab") { model.openInClaude(ws) }
                Button("Chat with Claude here") { _ = model.newChat(folder: ws.folderURL) }
                Divider()
                Button("Open folder in \(EditorChoice.current.name)") { model.openInEditor(ws) }
            } label: {
                Text("Open in Claude").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.primary)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            } primaryAction: {
                model.openInClaude(ws)
            }
            .menuStyle(.button).buttonStyle(.plain)
            .glassPill()
            .fixedSize()
            .help("Starts Claude Code in this folder, in a Taki tab. Hold for a chat or the folder.")
            Button { model.refreshFacts(); model.poll() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain).help("Refresh").padding(.horizontal, 6)
            if ws.services.isEmpty {
                // Nothing of Taki's to start or stop: say what is live instead of a dead switch.
                if model.isLive(ws) {
                    Label("Live", systemImage: "circle.fill").labelStyle(StatusLabelStyle(color: Theme.live))
                        .help("Something runs here outside Taki: a terminal, an agent or Docker")
                }
            } else {
                Text(running ? "Running" : "Stopped").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(running ? Theme.live : Theme.secondary)
                Toggle("", isOn: Binding(get: { running }, set: { $0 ? model.startAll(ws) : model.stopAll(ws) }))
                    .toggleStyle(.switch).labelsHidden().tint(Theme.live)
                    .help(running ? "Stop every service" : "Start every service")
            }
        }
    }
}

/// Uptime, CPU, Memory, Energy. Below about 200 pt per tile they go compact: a smaller number,
/// a short caption, no chart, so nothing is ever cut off.
struct StatTiles: View {
    @Environment(AppModel.self) private var model
    let ws: Workspace
    @State private var width: CGFloat = 900

    private var compact: Bool { (width - 3 * Theme.gutter) / 4 < 200 }

    var body: some View {
        let s = model.monitor.stats[ws.id] ?? ResourceMonitor.Stats()
        // The oldest of what runs here: Taki's own services, then servers started elsewhere.
        let started = (ws.services.compactMap { model.runner.running[$0.id]?.startedAt }
                       + model.externalServers(in: ws).compactMap(\.startedAt)).min()
        let (memV, memU) = Format.bytes(s.memory)
        let size: CGFloat = compact ? 30 : 36
        let total = Format.bytes(ProcessScanner.physicalMemory)
        HStack(spacing: Theme.gutter) {
            Card("Uptime") {
                if let started {
                    let (v, u) = uptime(started)
                    StatNumber(value: v, unit: u, caption: "Since \(Format.clock(started))", size: size)
                } else {
                    StatNumber(value: "0", unit: "m", caption: model.containers(in: ws).isEmpty ? "Not running" : "Running in Docker",
                               size: size)
                }
            }
            Card("CPU") {
                HStack(alignment: .center) {
                    StatNumber(value: String(format: "%.0f", s.cpu), unit: "%",
                               caption: compact ? "Peak \(String(format: "%.0f", s.cpuPeak))%"
                                                : "Peak \(String(format: "%.0f", s.cpuPeak))% · 5 min", size: size)
                    if !compact { Spacer(minLength: 4); Sparkline(values: Array(s.cpuHistory.suffix(7))) }
                }
            }
            Card("Memory") {
                HStack(alignment: .center) {
                    StatNumber(value: memV, unit: memU, caption: "of \(total.0) \(total.1)", size: size)
                    if !compact { Spacer(minLength: 4); Sparkline(values: Array(s.memHistory.suffix(7))) }
                }
            }
            Card("Energy") {
                let w = s.watts ?? 0
                let avg = s.wattsAverage ?? w
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", w)).font(.system(size: size, weight: .medium)).monospacedDigit()
                        Text("W").font(.system(size: size * 0.5)).foregroundStyle(Theme.secondary)
                    }
                    (Text(EnergyLevel.label(avg)).foregroundStyle(EnergyLevel.color(avg))
                     + Text(compact ? "" : " · average this hour").foregroundStyle(Theme.secondary))
                        .font(.system(size: 14)).lineLimit(1)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !compact {
                    let avg = s.wattsAverage ?? (s.watts ?? 0)
                    EnergyGauge(value: avg / EnergyLevel.gaugeFullWatts, color: EnergyLevel.color(avg))
                        .padding(.top, 14).padding(.trailing, 16)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func uptime(_ since: Date) -> (String, String) {
        let m = Int(Date().timeIntervalSince(since) / 60)
        return m < 60 ? ("\(m)", "m") : ("\(m / 60)", "h \(m % 60)m")
    }
}

/// Agents working in this workspace, with their context use.
struct WorkspaceAgentsCard: View {
    @Environment(AppModel.self) private var model
    let ws: Workspace

    var body: some View {
        let agents = model.agents(in: ws)
        Card("Agents", badge: "\(agents.count)") {
            if agents.isEmpty {
                LinkButton("+ Chat") { _ = model.newChat(folder: ws.folderURL) }
            } else {
                Text("Context").font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
        } content: {
            if agents.isEmpty {
                Text("No agent is working in this folder.").font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    ForEach(agents) { a in
                        HStack(spacing: 12) {
                            AgentGlyph(tool: a.tool)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.task).font(.system(size: 15, weight: .medium)).lineLimit(1)
                                Text(a.subtitle(style: .compact)).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if a.contextTokens > 0, a.status != .idle {
                                ContextMeter(share: ChatSession.contextShare(a.contextTokens), barWidth: 36)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.open(a) }
                        .help("Open: go to where it is running")
                        .contextMenu { AgentMenu(agent: a) }
                    }
                }
            }
        }
    }
}

/// A small colored dot and a medium label, for a status word in a header.
struct StatusLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(color)
            configuration.title.font(.system(size: 15, weight: .medium)).foregroundStyle(color)
        }
    }
}
