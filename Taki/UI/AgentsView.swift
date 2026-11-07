import SwiftUI

/// Every coding agent on the Mac in one place (the ones waiting for you first), plan limits,
/// tokens, the last 24 hours, and the apps using the Mac's memory.
struct AgentsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.gutter) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agents").font(.system(size: 20, weight: .semibold))
                        Text("\(model.agents.count) live on this Mac · "
                             + (model.usageReady ? "\(Format.tokens(model.usage.tokensToday)) tokens today" : "reading usage..."))
                            .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Menu {
                        ForEach(TabKind.menuKinds, id: \.self) { kind in
                            Button("\(kind.menuName) in a folder...") { model.newTerminalInChosenFolder(kind) }
                        }
                    } label: {
                        Text("New").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.primary)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
                    .glassPill().fixedSize()
                    .help(Edition.isPro ? "A new chat, or Claude Code, Codex or a shell in a tab."
                                        : "Claude Code, Codex or a shell in a new tab.")
                }
                .frame(height: 44)

                HStack(alignment: .top, spacing: Theme.gutter) {
                    LimitsCard()
                    Card("Tokens") {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            tokensToday.frame(maxWidth: .infinity, alignment: .leading)
                            tokensWeek.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    Card("Last 24 hours") {
                        Text(Format.plural(model.usage.sessions24h, "session")).font(.system(size: 14, weight: .medium))
                    } content: {
                        ActivityBars(values: model.usage.sessionsPerHour.map(Double.init), compact: true)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(height: Self.topRowHeight)

                Card("Live", badge: "\(model.agents.count)", fill: false) {
                    if !model.agents.isEmpty { Text("Context").font(.system(size: 14)).foregroundStyle(Theme.secondary) }
                } content: {
                    if model.agents.isEmpty {
                        Text("Nothing running. Claude Code, Codex and Cursor sessions show up here wherever you start them.")
                            .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    }
                    VStack(spacing: 14) { ForEach(model.agents) { AgentRow(agent: $0) } }
                }

                SystemCard()
            }
            .screenPadding()
        }
        .scrollEdgeEffectStyle(.soft, for: .top)   // cards fade at the window's top edge, never cut hard
    }

    /// The three cards on top share one height, so their titles and contents line up.
    static let topRowHeight: CGFloat = 148

    private var tokensToday: some View {
        StatNumber(value: model.usageReady ? Format.tokens(model.usage.tokensToday) : "...", caption: "Today", size: 32)
    }

    private var tokensWeek: some View {
        StatNumber(value: model.usageReady ? Format.tokens(model.usage.claudeTokensWeek + model.usage.codexTokensWeek) : "...",
                   caption: "Last 7 days", size: 32)
    }

}

struct AgentRow: View {
    @Environment(AppModel.self) private var model
    let agent: LiveAgent

    var body: some View {
        HStack(spacing: 12) {
            AgentGlyph(tool: agent.tool)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.task).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Text(agent.subtitle(style: .full)).font(.system(size: 13)).foregroundStyle(statusColor).lineLimit(1)
            }
            Spacer(minLength: 12)
            if agent.contextTokens > 0 {
                ContextMeter(share: ContextWindow.share(agent.contextTokens))
            }
            AgentButtons(agent: agent)
        }
        .contextMenu { AgentMenu(agent: agent) }
    }

    private var statusColor: Color {
        switch agent.status {
        case .working: Theme.busy
        case .waiting: Theme.link
        case .idle: Theme.secondary
        }
    }
}

/// Claude plan limits: the 5-hour and weekly windows with their reset times.
struct LimitsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card("Claude limits") {
            LinkButton(model.checkingLimits ? "Checking..." : (model.limits == nil ? "Connect..." : "Refresh")) {
                model.checkClaudeLimits()
            }
            .help("Reads your plan limits with one tiny Haiku request through Claude Code. Every Taki chat updates them too.")
        } content: {
            HStack(spacing: 22) {
                limit("5 hours", model.limits?.fiveHourUsed, model.limits?.fiveHourResets)
                limit("Week", model.limits?.weekUsed, model.limits?.weekResets)
            }
        }
    }

    private func limit(_ title: String, _ used: Double?, _ reset: Date?) -> some View {
        HStack(spacing: 12) {
            Ring(value: used, color: (used ?? 0) > 0.8 ? Theme.danger : Theme.claude) {
                Text(used.map { "\(Int($0 * 100))%" } ?? "-").font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .medium))
                Text(reset.map { "Resets \(Format.clock($0))" } ?? "Not read yet").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).fixedSize()
            }
        }
    }
}

/// Bars per hour for the last 24 hours, the last two in the accent, with the start time and Now.
struct ActivityBars: View {
    let values: [Double]
    var compact = false

    var body: some View {
        let maxV = max(values.max() ?? 1, 1)
        let cal = Calendar.current
        let start = (cal.dateInterval(of: .hour, for: Date())?.start ?? Date()).addingTimeInterval(-23 * 3600)
        let startLabel = (cal.isDateInToday(start) ? "Today " : "Yesterday ")
            + start.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: compact ? 3 : 4) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous)
                        .fill(i >= values.count - 3 && v > 0 ? Theme.busy : Theme.tertiary)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, CGFloat(v / maxV) * (compact ? 52 : 72)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            HStack {
                Text(startLabel); Spacer(); Text("Now")
            }
            .font(.system(size: compact ? 11 : 13)).foregroundStyle(Theme.secondary)
        }
    }
}

/// Apps and system: Mac memory in use, and the apps holding the most of it in two columns that
/// fill the card, each with a bar against the largest.
struct SystemCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sys = model.system
        let share = sys.totalMemory > 0 ? Double(sys.usedMemory) / Double(sys.totalMemory) : 0
        let top = max(sys.apps.map(\.memory).max() ?? 1, 1)
        Card("Apps and system", fill: false) {
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 10) {
                    StatNumber(value: Format.bytes(sys.usedMemory).0, unit: Format.bytes(sys.usedMemory).1,
                               caption: "of \(Format.bytesText(sys.totalMemory)) memory in use", size: 32)
                    ThinBar(value: share, color: share > 0.85 ? Theme.danger : share > 0.7 ? Theme.busy : Theme.live)
                }
                .frame(width: 230, alignment: .leading)
                if sys.apps.isEmpty {
                    Text("Reading...").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 32), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        ForEach(sys.apps) { app in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(app.name).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(Format.bytesText(app.memory)).foregroundStyle(Theme.secondary).monospacedDigit()
                                }
                                .font(.system(size: 14))
                                ThinBar(value: Double(app.memory) / Double(top), color: Theme.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }
}
