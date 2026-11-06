import AppKit
import SwiftUI

/// ⌥Space palette: open, restart or stop any workspace, chat or agent from anywhere.
@MainActor
final class PaletteWindow: NSPanel {
    init(model: AppModel, openMain: @escaping () -> Void) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        contentView = NSHostingView(rootView: PaletteView(close: { [weak self] in self?.close() }, openMain: openMain)
            .environment(model))
    }

    override var canBecomeKey: Bool { true }

    func present() {
        center()
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }
}

struct PaletteView: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    let openMain: () -> Void
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let icon: String
        let run: () -> Void
    }

    private var actions: [Action] {
        var list: [Action] = []
        for ws in model.workspaces {
            let running = model.isRunning(ws)
            list.append(.init(title: "Open \(ws.name)", subtitle: ws.displayFolder, icon: "macwindow") {
                model.section = .workspace(ws.id); openMain()
            })
            if !ws.services.isEmpty {
                if running {
                    list.append(.init(title: "Restart \(ws.name)", subtitle: "Stop and start every service", icon: "arrow.clockwise") {
                        model.stopAll(ws)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { model.startAll(ws) }
                    })
                    list.append(.init(title: "Stop \(ws.name)", subtitle: ws.services.count == 1 ? "1 service" : "\(ws.services.count) services", icon: "stop.fill") { model.stopAll(ws) })
                } else {
                    list.append(.init(title: "Start \(ws.name)", subtitle: ws.services.map(\.command).joined(separator: ", "), icon: "play.fill") { model.startAll(ws) })
                }
            }
            list.append(.init(title: "Chat in \(ws.name)", subtitle: "New Claude chat", icon: "plus.bubble") {
                _ = model.newChat(folder: ws.folderURL); openMain()
            })
            list.append(.init(title: "Terminal in \(ws.name)", subtitle: ws.displayFolder, icon: "terminal") {
                model.newTerminal(folder: ws.folder); openMain()
            })
        }
        for chat in model.chats {
            list.append(.init(title: chat.title, subtitle: "Chat", icon: "bubble.left") { model.section = .chat(chat.id); openMain() })
        }
        for a in model.agents {
            list.append(.init(title: a.task, subtitle: "\(a.tool.rawValue) in \(a.folderName)", icon: "asterisk") { model.open(a); openMain() })
            list.append(.init(title: "Stop: \(a.task)", subtitle: a.folderName, icon: "stop.circle") { model.stopAgent(a) })
        }
        for s in model.externalServers {
            list.append(.init(title: "Open :" + String(s.port), subtitle: s.cwd.isEmpty ? s.command : s.cwd, icon: "globe") {
                if let u = URL(string: "http://localhost:\(s.port)") { NSWorkspace.shared.open(u) }
            })
        }
        list.append(.init(title: "Clean up", subtitle: Format.bytesText(model.cleanup.totalBytes), icon: "shippingbox") {
            model.section = .cleanup; openMain()
        })
        guard !query.isEmpty else { return list }
        return list.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let items = actions
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "water.waves").foregroundStyle(Theme.link)
                TextField("Open, restart or stop...", text: $query).textFieldStyle(.plain).font(.system(size: 18))
                    .focused($focused)
                    .onSubmit { run(items) }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(0, items.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
            }
            .padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, a in
                            HStack(spacing: 12) {
                                Image(systemName: a.icon).frame(width: 20).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(a.title).lineLimit(1)
                                    Text(a.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(i == selection ? Theme.selection : .clear, in: .rect(cornerRadius: 8))
                            .contentShape(Rectangle())
                            .onTapGesture { selection = i; run(items) }
                            .id(i)
                        }
                        if items.isEmpty { Text("Nothing matches.").foregroundStyle(.secondary).padding() }
                    }
                    .padding(8)
                }
                .onChange(of: selection) { proxy.scrollTo(selection) }
            }
        }
        .frame(width: 560, height: 380)
        .background(LinearGradient(colors: [Theme.windowTop, Theme.windowBottom], startPoint: .top, endPoint: .bottom),
                    in: .rect(cornerRadius: 18, style: .continuous))
        .foregroundStyle(Theme.primary)
        .onAppear { focused = true }
        .onChange(of: query) { selection = 0 }
    }

    private func run(_ items: [Action]) {
        guard items.indices.contains(selection) else { return }
        let a = items[selection]
        close()
        a.run()
    }
}
