import SwiftUI

/// A context bar and its percent, amber once past `Theme.contextWarn`.
struct ContextMeter: View {
    let share: Double
    var barWidth: CGFloat = 60

    var body: some View {
        let warn = share > Theme.contextWarn
        ThinBar(value: share, color: warn ? Theme.busy : Theme.codexBlue).frame(width: barWidth)
        Text("\(Int(share * 100))%").font(.system(size: 14).monospacedDigit())
            .foregroundStyle(warn ? Theme.busy : Theme.primary).frame(width: 40, alignment: .trailing)
    }
}

/// The same right-click menu for a live agent wherever it is listed.
struct AgentMenu: View {
    @Environment(AppModel.self) private var model
    let agent: LiveAgent
    var canStop = true

    var body: some View {
        Button("Open where it runs") { model.open(agent) }
        if agent.tool == .claude { Button("Continue in Claude Code") { model.continueInTaki(agent) } }
        if canStop {
            Divider()
            Button("Stop", role: .destructive) { model.stopAgent(agent) }
        }
    }
}

/// Stop and Open for a live agent: a glass circle with a stop square, and a
/// glass circle holding a white tile with a blue chevron.
struct AgentButtons: View {
    @Environment(AppModel.self) private var model
    let agent: LiveAgent
    var size: CGFloat = 28
    var afterOpen: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Button { model.stopAgent(agent) } label: {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.secondary).frame(width: size * 0.3, height: size * 0.3)
                    .frame(width: size, height: size).glassCircle()
            }
            .buttonStyle(.plain).help("Stop this agent (Ctrl-C)")
            Button { model.open(agent); afterOpen() } label: {
                Image(systemName: "chevron.right").font(.system(size: size * 0.36, weight: .bold)).foregroundStyle(Theme.link)
                    .frame(width: size * 0.62, height: size * 0.62)
                    .background(.white, in: .rect(cornerRadius: size * 0.17, style: .continuous))
                    .frame(width: size, height: size).glassCircle()
            }
            .buttonStyle(.plain).help("Open: go to where it is running")
        }
    }
}
