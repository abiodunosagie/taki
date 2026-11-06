import SwiftUI

/// Live service output: a segmented filter (All, one per service, Errors), search, and a dark
/// monospaced panel with each service in its own color.
struct LogsCard: View {
    @Environment(AppModel.self) private var model
    let workspaceID: UUID
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var searching = false

    enum Filter: Hashable { case all, errors, service(String) }

    static let maxShown = 800

    var body: some View {
        if let ws = model.workspaces.first(where: { $0.id == workspaceID }) {
            let all = model.runner.logs[workspaceID] ?? []
            let errors = all.lazy.filter(\.isError).count
            let lines = visible(all)
            Card("Logs") {
                HStack(spacing: 10) {
                    if searching {
                        TextField("Search", text: $search).textFieldStyle(.plain).font(.system(size: 13)).frame(width: 140)
                    }
                    HStack(spacing: 2) {
                        chip("All", .all)
                        ForEach(ws.services) { s in chip(s.name, .service(s.name)) }
                        chip("Errors \(errors)", .errors)
                    }
                    .padding(3)
                    .background(Theme.field, in: .capsule)
                    Menu {
                        Button("Copy visible lines") {
                            let text = lines.map { "\(Format.logClock($0.time)) \($0.service) \($0.text)" }.joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        Button("Clear") { model.runner.clearLogs(workspaceID) }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.secondary)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    Button { searching.toggle(); if !searching { search = "" } } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } content: {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(lines) { l in
                                HStack(alignment: .firstTextBaseline, spacing: 14) {
                                    Text(Format.logClock(l.time)).foregroundStyle(Theme.secondary)
                                    Text(l.service).foregroundStyle(color(for: l.service, in: ws))
                                        .frame(minWidth: 48, alignment: .leading)
                                    Text(l.text).foregroundStyle(l.isError ? Theme.danger : Theme.primary.opacity(0.9))
                                        .textSelection(.enabled)
                                }
                                .font(.system(size: 13, design: .monospaced))
                                .id(l.id)
                            }
                            if lines.isEmpty {
                                Text(all.isEmpty ? "Start a service to see its output here." : "No line matches.")
                                    .font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    }
                    .background(Theme.inset, in: .rect(cornerRadius: 12, style: .continuous))
                    .onChange(of: lines.last?.id) { if let id = lines.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
        }
    }

    private func visible(_ all: [LogLine]) -> [LogLine] {
        let scoped: [LogLine]
        switch filter {
        case .all: scoped = all
        case .errors: scoped = all.filter(\.isError)
        case let .service(name): scoped = all.filter { $0.service == name }
        }
        let recent = scoped.suffix(Self.maxShown)
        return search.isEmpty ? Array(recent) : recent.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    private func chip(_ title: String, _ value: Filter) -> some View {
        Button { filter = value } label: {
            Text(title).font(.system(size: 13, weight: .medium))
                .foregroundStyle(filter == value ? Theme.primary : Theme.secondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(filter == value ? Theme.tileRaised : .clear, in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func color(for service: String, in ws: Workspace) -> Color {
        let palette = [Theme.link, Theme.busy, Theme.live, Color(light: 0xC2399B, dark: 0xF28CD3), Color(light: 0x7B55E0, dark: 0xB79CFF)]
        let i = ws.services.firstIndex { $0.name == service } ?? 0
        return palette[i % palette.count]
    }
}
