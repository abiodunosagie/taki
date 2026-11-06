import SwiftUI

/// Every terminal inside Taki. One switcher at the top (a dropdown that lists every tab, grouped
/// by folder, with a filter once there are many), a + for a new tab, and the terminal below.
/// Keyboard: Cmd-T new, Cmd-W close, Cmd-1...9, Cmd-Shift-[ and ].
struct TerminalsView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming = false
    @State private var draftName = ""
    @State private var picking = false
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            toolbar
            if let tab = model.terminals.first(where: { $0.id == model.selectedTerminal }) ?? model.terminals.first {
                TerminalHost(tab: tab, model: model)
                    .id(tab.id)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Theme.terminalBackground)
                    .clipShape(.rect(cornerRadius: 14, style: .continuous))
                    .onAppear { if model.selectedTerminal == nil { model.selectedTerminal = tab.id } }
            } else {
                Color.clear.onAppear { model.newTerminalTab() }   // the screen is never an empty placeholder
            }
        }
        .screenPadding()
        .confirmationDialog(closeTitle, isPresented: Binding(get: { !model.pendingClose.isEmpty },
                                                            set: { if !$0 { model.pendingClose = [] } })) {
            Button(model.pendingClose.count == 1 ? "Close tab" : "Close \(model.pendingClose.count) tabs", role: .destructive) {
                model.confirmPendingClose()
            }
        } message: {
            Text("What is running there will be stopped.")
        }
    }

    private var closeTitle: String {
        model.pendingClose.count == 1
            ? "\(model.terminals.first { $0.id == model.pendingClose[0] }.map { model.displayTitle($0) } ?? "This tab") is still running something."
            : "\(model.pendingClose.count) tabs are still running something."
    }

    private var current: TerminalTab? { model.terminals.first { $0.id == model.selectedTerminal } }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if renaming, let t = current {
                // Renaming replaces the switcher with a plain field, so a click lands in the field.
                HStack(spacing: 10) {
                    TabGlyph(tab: t)
                    TextField("Tab name", text: $draftName).textFieldStyle(.plain).font(.system(size: 14, weight: .medium))
                        .focused($renameFocused)
                        .onSubmit { model.renameTerminal(t.id, to: draftName); renaming = false }
                        .onExitCommand { renaming = false }
                        .onChange(of: renameFocused) { _, focused in if !focused { renaming = false } }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: 560, alignment: .leading)
                .tileSurface(radius: 12)
                .onAppear { renameFocused = true }
            } else {
                switcher
            }
            newMenu
            Spacer()
        }
    }

    private var switcher: some View {
        Button { picking.toggle() } label: {
            HStack(spacing: 10) {
                if let t = current {
                    TabGlyph(tab: t)
                    Text(model.displayTitle(t)).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text(shortPath(TerminalRegistry.shared.currentFolder(of: t.id) ?? t.folder))
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 8)
                Text("\(model.terminals.firstIndex { $0.id == model.selectedTerminal }.map { $0 + 1 } ?? 0) of \(model.terminals.count)")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.tertiary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: 560, alignment: .leading)
            .tileSurface(radius: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $picking, arrowEdge: .bottom) { TabPicker(close: { picking = false }) }
        .help("Every open terminal (Cmd-1 to Cmd-9, Cmd-Shift-[ and ])")
        .contextMenu {
            if let t = current {
                Button("Rename...") { draftName = model.displayTitle(t); renaming = true }
                Button("Duplicate") { model.duplicateTerminal(t.id) }
                Button("Open folder in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: TerminalRegistry.shared.currentFolder(of: t.id) ?? t.folder))
                }
                Divider()
                Button("Close tab", role: .destructive) { model.requestClose(t.id) }
            }
        }
    }

    private var newMenu: some View {
        Menu {
            let folder = model.currentTerminalFolder
            let name = (folder as NSString).lastPathComponent
            Button("Shell in \(name)") { model.newTerminal(.shell, folder: folder) }
            Button("Claude Code in \(name)") { model.newTerminal(.claude, folder: folder) }
            Button("Codex in \(name)") { model.newTerminal(.codex, folder: folder) }
            if !model.workspaces.isEmpty {
                Divider()
                ForEach(model.workspaces) { ws in
                    Menu(ws.name) {
                        Button("Shell") { model.newTerminal(.shell, folder: ws.folder, name: ws.name) }
                        Button("Claude Code") { model.newTerminal(.claude, folder: ws.folder, name: ws.name) }
                        Button("Codex") { model.newTerminal(.codex, folder: ws.folder, name: ws.name) }
                    }
                }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
                .frame(width: 34, height: 34)
        } primaryAction: {
            model.newTerminalTab()
        }
        .menuStyle(.button).buttonStyle(.plain)
        .tileSurface(radius: 12)
        .fixedSize()
        .help("New tab (Cmd-T). Hold for Claude Code, Codex or another project.")
    }

    private func shortPath(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }
}
