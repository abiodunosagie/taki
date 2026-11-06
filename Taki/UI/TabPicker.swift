import SwiftUI

/// What a tab runs, at a glance: Claude's mark, Codex, or a plain shell.
struct TabGlyph: View {
    let tab: TerminalTab
    var size: CGFloat = 12
    var body: some View {
        Image(systemName: tab.isClaude ? "asterisk" : tab.isCodex ? "apple.terminal" : "terminal")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tab.isClaude ? Theme.claude : Theme.secondary)
            .frame(width: size + 4)
    }
}

/// The dropdown: every tab grouped by folder, a filter (focused, so typing narrows at once),
/// arrow keys and Return to switch, close buttons, and bulk close at the bottom.
struct TabPicker: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    @State private var query = ""
    @State private var cursor = 0
    @FocusState private var focused: Bool

    private var matches: [TerminalTab] {
        guard !query.isEmpty else { return model.terminals }
        return model.terminals.filter {
            model.displayTitle($0).localizedCaseInsensitiveContains(query) || $0.folder.localizedCaseInsensitiveContains(query)
        }
    }

    /// Matching tabs grouped by project, in the order they are drawn. The arrow keys walk `flat`,
    /// so the highlight always moves to the row below or above on screen.
    private var grouped: (order: [String], groups: [String: [TerminalTab]], flat: [TerminalTab]) {
        let list = matches
        let root = { (t: TerminalTab) in ProjectRoot.of(t.folder) ?? t.folder }
        let groups = Dictionary(grouping: list, by: root)
        let order = list.map(root).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return (order, groups, order.flatMap { groups[$0] ?? [] })
    }

    var body: some View {
        let (order, groups, list) = grouped
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField("Find a terminal", text: $query).textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
                    .onSubmit { pick(list) }
                    .onKeyPress(.downArrow) { cursor = min(cursor + 1, max(0, list.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { cursor = max(cursor - 1, 0); return .handled }
            }
            .padding(10)
            Divider().opacity(0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(order, id: \.self) { root in
                            Text((root as NSString).lastPathComponent).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.tertiary).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                            ForEach(groups[root] ?? []) { t in row(t, highlighted: list.firstIndex(of: t) == cursor).id(t.id) }
                        }
                        if list.isEmpty {
                            Text("No terminal matches.").font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(12)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 380)
                .onChange(of: cursor) { if list.indices.contains(cursor) { proxy.scrollTo(list[cursor].id) } }
            }
            Divider().opacity(0.5)
            HStack {
                Button("Close others") { model.closeOtherTerminals(); close() }.buttonStyle(.plain)
                    .disabled(model.terminals.count < 2)
                Spacer()
                Button("Close all") { model.closeAllTerminals(); close() }.buttonStyle(.plain)
            }
            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 420)
        .onAppear {
            focused = true
            cursor = grouped.flat.firstIndex { $0.id == model.selectedTerminal } ?? 0
        }
        .onChange(of: query) { cursor = 0 }
    }

    private func row(_ t: TerminalTab, highlighted: Bool) -> some View {
        let selected = t.id == model.selectedTerminal
        let busy = model.terminalIsBusy(t.id)
        return HStack(spacing: 10) {
            TabGlyph(tab: t)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayTitle(t)).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Text(((TerminalRegistry.shared.currentFolder(of: t.id) ?? t.folder) as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 6)
            if busy { Text("running").font(.system(size: 11)).foregroundStyle(Theme.busy) }
            if let n = model.terminals.firstIndex(of: t), let key = model.shortcut(forTerminalAt: n) {
                Text("⌘\(key)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
            }
            Button { model.requestClose(t.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain).help("Close")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(highlighted ? Theme.selection : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedTerminal = t.id; close(); TerminalRegistry.shared.focus(t.id) }
    }

    private func pick(_ list: [TerminalTab]) {
        guard list.indices.contains(cursor) else { return }
        model.selectedTerminal = list[cursor].id
        close()
        TerminalRegistry.shared.focus(list[cursor].id)
    }
}
