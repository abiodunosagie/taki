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
            if model.tabLimitReached { tabLimitNote }
            if let tab = model.terminals.first(where: { $0.id == model.selectedTerminal }) ?? model.terminals.first {
                TerminalHost(tab: tab, model: model)
                    .id(tab.id)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Theme.terminalBackground)
                    .clipShape(.rect(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .bottom) { DictationStrip(dictation: PushToTalk.shared.dictation).padding(14) }
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
            DictateButton(dictation: PushToTalk.shared.dictation) {
                PushToTalk.shared.toggle(into: current.flatMap { TerminalRegistry.shared.existingView($0.id) })
            }
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
        .accessibilityLabel("Switch tab")
        .accessibilityValue(current.map { model.displayTitle($0) } ?? "")
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

    /// Shown when the free edition's tab limit stopped a new tab. Close a tab, or get Taki Pro.
    private var tabLimitNote: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack").foregroundStyle(Theme.secondary)
            Text("Taki keeps \(Edition.maxTerminals) tabs open at once. Close one, or get Taki Pro for as many as you like.")
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            LinkButton("See Taki Pro") { if let url = URL(string: Edition.upgradeURL) { NSWorkspace.shared.open(url) } }
            Button { model.tabLimitReached = false } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain).help("Dismiss").accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .tileSurface(radius: 12)
    }

    private var newMenu: some View {
        NewTerminalMenu {
            Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
                .frame(width: 34, height: 34)
        }
        .tileSurface(radius: 12)
        .fixedSize()
        .help("New tab: pick a folder and a shell or an agent. Cmd-T opens a shell here.")
        .accessibilityLabel("New tab")
    }

    private func shortPath(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }
}

/// The new-tab menu behind every terminal +. One click opens it: the current folder, a folder
/// picked from disk, (Pro) workspaces and recent projects, each as a shell, Claude Code or Codex.
/// Cmd-T stays the one-key shell in the current folder.
struct NewTerminalMenu<Label: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder let label: Label

    var body: some View {
        Menu {
            let folder = model.currentTerminalFolder
            let kinds = TabKind.menuKinds
            Section("Start in \((folder as NSString).lastPathComponent)") {
                ForEach(kinds, id: \.self) { kind in Button(kind.menuName) { model.newTerminal(kind, folder: folder) } }
            }
            Menu("Choose a folder") {
                ForEach(kinds, id: \.self) { kind in Button("\(kind.menuName) in a folder...") { model.newTerminalInChosenFolder(kind) } }
            }
            let recent = model.recentTerminalFolders
            if !recent.isEmpty {
                Section("Recent projects") {
                    ForEach(recent, id: \.self) { kindMenu(($0 as NSString).lastPathComponent, folder: $0) }
                }
            }
        } label: {
            label
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
    }

    private func kindMenu(_ name: String, folder: String) -> some View {
        Menu(name) {
            ForEach(TabKind.menuKinds, id: \.self) { kind in
                Button(kind.menuName) { model.newTerminal(kind, folder: folder, name: name) }
            }
        }
    }
}

/// The mic in the Terminals toolbar: click to dictate into the open tab, click again to type it.
/// Holding Right Option does the same without the mouse.
struct DictateButton: View {
    let dictation: VoiceDictation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: dictation.isActive ? "mic.fill" : "mic")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(dictation.isActive ? Theme.live : Theme.primary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tileSurface(radius: 12)
        .help(dictation.isActive ? "Stop and type what you said" : "Dictate into this tab (or hold Right Option)")
        .accessibilityLabel(dictation.isActive ? "Stop dictation" : "Dictate")
    }
}

/// Shown over the terminal while dictating: what is heard so far, live, or why it could not start.
struct DictationStrip: View {
    let dictation: VoiceDictation

    var body: some View {
        Group {
            switch dictation.state {
            case .idle:
                EmptyView()
            case let .preparing(note):
                strip(icon: "mic", tint: Theme.secondary, text: note + "...")
            case .listening:
                let heard = dictation.transcript.text
                strip(icon: "waveform", tint: Theme.live, text: heard.isEmpty ? "Listening. Let go to type it." : heard)
            case let .failed(message):
                strip(icon: "mic.slash", tint: Theme.secondary, text: message, dismiss: { dictation.clearFailure() })
            }
        }
        .animation(.easeOut(duration: 0.18), value: dictation.state)
    }

    private func strip(icon: String, tint: Color, text: String, dismiss: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).symbolEffect(.variableColor.iterative, isActive: dictation.state == .listening)
                .foregroundStyle(tint)
            Text(text).font(.system(size: 13)).lineLimit(3).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary).accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 640)
        .tileSurface(radius: 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
