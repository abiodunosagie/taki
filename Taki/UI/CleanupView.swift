import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var result: String?
    @State private var confirm = false

    var body: some View {
        let c = model.cleanup
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clean up").font(.system(size: 20, weight: .semibold))
                        Text("What finished agent sessions left behind. Everything goes to the Trash, so you can undo it.")
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    PillButton(title: c.scanning ? "Scanning..." : "Scan again") { scan() }.disabled(c.scanning)
                    let none = c.items.filter { !c.excluded.contains($0.id) }.isEmpty
                    Button { confirm = true } label: {
                        Text("Move \(Format.bytesText(c.totalBytes)) to the Trash").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 8)
                            .background(none ? Theme.tertiary : Theme.danger, in: .capsule)
                    }
                    .buttonStyle(.plain).disabled(none)
                }
                .padding(.top, 4)
                if let result { Text(result).foregroundStyle(Theme.live) }

                ForEach(CleanupItem.Kind.allCases, id: \.self) { kind in
                    let list = c.items.filter { $0.kind == kind }
                    Card(kind.rawValue, badge: list.isEmpty ? "nothing to clean" : Format.bytesText(c.bytes(kind)), fill: false) {
                        Text(kind.detail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        ForEach(list) { item in
                            HStack {
                                Toggle(isOn: Binding(get: { !c.excluded.contains(item.id) },
                                                     set: { on in if on { c.excluded.remove(item.id) } else { c.excluded.insert(item.id) } })) {
                                    Text(item.label).font(Theme.mono).lineLimit(1).truncationMode(.middle)
                                }
                                .toggleStyle(.checkbox)
                                Spacer()
                                Text(Format.bytesText(item.bytes)).foregroundStyle(Theme.secondary)
                                if item.pid == nil {
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                                        label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain).help("Show in Finder")
                                }
                            }
                        }
                    }
                }
                Text("Taki only offers what agent sessions created. It never touches a worktree with uncommitted changes, your own servers, or anything outside these four groups.")
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
            .screenPadding()
        }
        .onAppear { if c.lastScan == nil { scan() } }
        .confirmationDialog("Move \(Format.bytesText(c.totalBytes)) to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) {
                Task {
                    let r = await c.clean(liveAgentCwds: model.agents.map(\.cwd))
                    var parts = ["Moved \(r.moved) item\(r.moved == 1 ? "" : "s") to the Trash."]
                    if r.skipped > 0 { parts.append("\(r.skipped) changed since the scan and were left alone.") }
                    if r.failed > 0 { parts.append("\(r.failed) could not be moved.") }
                    result = parts.joined(separator: " ")
                }
            }
        } message: { Text("Selected orphan processes are ended. Files go to the Trash and can be put back.") }
    }

    private func scan() {
        model.cleanup.scan(workspaces: model.workspaces, liveAgentCwds: model.agents.map(\.cwd), busyFolders: model.busyFolders)
    }
}
