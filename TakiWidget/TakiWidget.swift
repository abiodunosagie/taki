import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snap: WidgetSnapshot()) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snap: WidgetSnapshot.load() ?? WidgetSnapshot()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let e = Entry(date: Date(), snap: WidgetSnapshot.load() ?? WidgetSnapshot())
        completion(Timeline(entries: [e], policy: .after(Date().addingTimeInterval(300))))
    }
}

private let claude = Color(red: 0.89, green: 0.45, blue: 0.29)
private let live = Color(red: 0.30, green: 0.82, blue: 0.45)
private let busy = Color(red: 1.0, green: 0.68, blue: 0.20)

private func tokens(_ n: Int) -> String {
    n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.0fK", Double(n) / 1e3) : "\(n)"
}

struct Header: View {
    let title: String
    let value: String
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold))
        }
    }
}

struct ServersView: View {
    @Environment(\.widgetFamily) var family
    let snap: WidgetSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(title: "Servers", value: "\(snap.servers.count)")
            if snap.servers.isEmpty { Text("Nothing running").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(snap.servers.prefix(family == .systemSmall ? 3 : 7).enumerated()), id: \.offset) { _, s in
                HStack {
                    Circle().fill(live).frame(width: 6, height: 6)
                    Text(s.name).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text(verbatim: ":\(s.port)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct AgentsWidgetView: View {
    @Environment(\.widgetFamily) var family
    let snap: WidgetSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(title: "Agents", value: "\(snap.agents.count) live")
            if snap.agents.isEmpty { Text("No agent running").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(snap.agents.prefix(family == .systemSmall ? 3 : 6).enumerated()), id: \.offset) { _, a in
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.task).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text("\(a.tool) · \(a.status) \(a.minutes)m").font(.system(size: 10))
                        .foregroundStyle(a.status == "working" ? busy : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct WorkspacesView: View {
    let snap: WidgetSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(title: "Workspaces", value: "\(snap.workspaces.filter(\.running).count) running")
            ForEach(Array(snap.workspaces.prefix(6).enumerated()), id: \.offset) { _, w in
                HStack {
                    Circle().fill(w.running ? live : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                    Text(w.name).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    if w.agents > 0 { Text("\(w.agents) agents").font(.system(size: 10)).foregroundStyle(busy) }
                    if w.running { Text("\(w.memoryMB) MB").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct UsageView: View {
    let snap: WidgetSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(title: "AI usage", value: "Today")
            Text(tokens(snap.tokensToday)).font(.system(size: 28, weight: .semibold, design: .rounded))
            Text("tokens, all agents").font(.caption).foregroundStyle(.secondary)
            let bars = snap.sessionsPerHour.suffix(24)
            let m = Double(max(bars.max() ?? 1, 1))
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(bars.enumerated()), id: \.offset) { i, v in
                    RoundedRectangle(cornerRadius: 1).fill(i >= bars.count - 2 ? busy : Color.secondary.opacity(0.4))
                        .frame(height: max(2, CGFloat(Double(v) / m) * 28))
                }
            }
            .frame(height: 28, alignment: .bottom)
        }
    }
}

struct LimitsView: View {
    let snap: WidgetSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(title: "Claude limits", value: "")
            ring("5 hours", snap.claudeFiveHour)
            ring("Week", snap.claudeWeek)
            if let r = snap.claudeFiveHourResets {
                Text("Resets \(r.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func ring(_ title: String, _ v: Double?) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 4)
                Circle().trim(from: 0, to: v ?? 0).stroke((v ?? 0) > 0.8 ? .red : claude, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 26, height: 26)
            Text(title).font(.system(size: 12))
            Spacer()
            Text(v.map { "\(Int($0 * 100))%" } ?? "-").font(.system(size: 13, weight: .semibold))
        }
    }
}

@MainActor
private func make<V: View>(_ kind: String, _ name: String, _ desc: String,
                           @ViewBuilder _ view: @escaping (WidgetSnapshot) -> V) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: Provider()) { e in
        view(e.snap).containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName(name)
    .description(desc)
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
}

struct ServersWidget: Widget {
    var body: some WidgetConfiguration { make("servers", "Servers", "Dev servers running on this Mac.") { ServersView(snap: $0) } }
}
struct AgentsWidget: Widget {
    var body: some WidgetConfiguration { make("agents", "Agents", "Claude Code and Codex sessions, live.") { AgentsWidgetView(snap: $0) } }
}
struct WorkspacesWidget: Widget {
    var body: some WidgetConfiguration { make("workspaces", "Workspaces", "Your projects and what is running.") { WorkspacesView(snap: $0) } }
}
struct UsageWidget: Widget {
    var body: some WidgetConfiguration { make("usage", "AI usage", "Tokens today and the last 24 hours.") { UsageView(snap: $0) } }
}
struct LimitsWidget: Widget {
    var body: some WidgetConfiguration { make("limits", "Claude limits", "Your 5-hour and weekly plan use.") { LimitsView(snap: $0) } }
}

@main
struct TakiWidgets: WidgetBundle {
    var body: some Widget {
        ServersWidget()
        AgentsWidget()
        WorkspacesWidget()
        UsageWidget()
        LimitsWidget()
    }
}
