import SwiftUI

/// The right column: Workspace (name, icon, folder, start at launch), Link, Environment, and
/// "Remove workspace..." pinned to the bottom.
struct WorkspaceSettingsColumn: View {
    @Environment(AppModel.self) private var model
    let workspaceID: UUID
    @State private var addingEnv = false
    @State private var confirmRemove = false
    @State private var showQR = false
    @State private var editingLink = false

    var body: some View {
        @Bindable var model = model
        if let i = model.workspaces.firstIndex(where: { $0.id == workspaceID }) {
            let ws = model.workspaces[i]
            VStack(spacing: Theme.gutter) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: Theme.gutter) {
                        workspaceCard(ws, i: i)
                        linkCard(ws, i: i)
                        envCard(ws, i: i)
                    }
                }
                HStack {
                    Spacer()
                    Button { confirmRemove = true } label: {
                        Label("Remove workspace...", systemImage: "trash").font(.system(size: 15)).foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 6).padding(.bottom, 4)
            }
            .sheet(isPresented: $addingEnv) { AddEnvSheet(workspaceID: workspaceID) }
            .confirmationDialog("Remove \(ws.name) from Taki?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { model.removeWorkspace(ws) }
            } message: {
                Text("Its services stop and its Keychain variables are deleted. The folder and its files stay where they are.")
            }
        }
    }

    private func workspaceCard(_ ws: Workspace, i: Int) -> some View {
        @Bindable var model = model
        return Card("Workspace", fill: false) {
            VStack(alignment: .leading, spacing: 14) {
                labeled("Name") {
                    FieldBox {
                        TextField("", text: $model.workspaces[i].name).textFieldStyle(.plain).font(.system(size: 15))
                    }
                }
                labeled("Icon") {
                    HStack(spacing: 10) {
                        WorkspaceBadge(symbol: ws.iconOverride ?? model.facts[ws.id]?.symbol ?? "folder", name: ws.name,
                                       logo: model.logo(of: ws), size: 26)
                        Text(ws.iconOverride == nil ? "Automatic" : "Custom").font(.system(size: 15)).lineLimit(1).fixedSize()
                        Spacer()
                        Menu {
                            Button("Automatic") { model.workspaces[i].iconOverride = nil }
                            Divider()
                            ForEach(Brand.colors.keys.sorted(), id: \.self) { key in
                                Button(key.replacingOccurrences(of: "dotjs", with: ".js")) { model.workspaces[i].iconOverride = "logo:" + key }
                            }
                            Divider()
                            ForEach(["bolt.fill", "drop.fill", "leaf.fill", "flame.fill", "star.fill", "cube.fill",
                                     "globe", "server.rack", "iphone", "paintbrush.fill"], id: \.self) { sym in
                                Button { model.workspaces[i].iconOverride = sym } label: { Label(sym, systemImage: sym) }
                            }
                        } label: { Text("Change...").font(.system(size: 14)).foregroundStyle(Theme.link) }
                            .menuStyle(.button).buttonStyle(.plain).fixedSize()
                    }
                }
                labeled("Folder") {
                    HStack {
                        Text(ws.displayFolder).font(.system(size: 13, design: .monospaced)).lineLimit(1).truncationMode(.head).minimumScaleFactor(0.85)
                        Spacer()
                        LinkButton("Change...") { changeFolder(i) }
                    }
                }
                Divider().opacity(0.4)
                Toggle(isOn: $model.workspaces[i].startAtLaunch) {
                    Text("Start when Taki opens").font(.system(size: 15))
                }
                .toggleStyle(.switch).tint(Theme.live)
            }
        }
    }

    private func linkCard(_ ws: Workspace, i: Int) -> some View {
        let port = ws.services.lazy.compactMap { model.servicePorts[$0.id] }.first
        let short = LocalProxy.shared.isOn
        let link = "\(ws.linkName).localhost" + (short ? "" : port.map { ":" + String($0) } ?? "")
        return Card("Link", fill: false) {
            LinkButton("Open") { if let u = URL(string: "http://\(link)") { NSWorkspace.shared.open(u) } }
                .disabled(port == nil).opacity(port == nil ? 0.5 : 1)
        } content: {
            HStack(spacing: 12) {
                FieldBox {
                    if editingLink {
                        TextField("", text: Binding(get: { ws.linkName },
                                                    set: { model.workspaces[i].linkName = WorkspaceStore.linkName(for: $0) }))
                            .textFieldStyle(.plain).font(.system(size: 14, design: .monospaced))
                            .onSubmit { editingLink = false }
                    } else {
                        Text(link).font(.system(size: 13, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            .minimumScaleFactor(0.85)
                            .onTapGesture(count: 2) { editingLink = true }
                            .help("Double-click to rename the link")
                    }
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("http://\(link)", forType: .string)
                } label: { Image(systemName: "doc.on.doc").font(.system(size: 16)).foregroundStyle(Theme.secondary) }
                    .buttonStyle(.plain).help("Copy link")
                Button { showQR.toggle() } label: {
                    Image(systemName: "qrcode").font(.system(size: 16)).foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain).help("Open on your phone (same Wi-Fi)")
                .popover(isPresented: $showQR) { QRPopover(port: port) }
            }
        }
    }

    private func envCard(_ ws: Workspace, i: Int) -> some View {
        Card("Environment", fill: false) {
            LinkButton("+ Add") { addingEnv = true }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(ws.envNames, id: \.self) { name in
                    HStack {
                        Text(name).font(.system(size: 14, design: .monospaced))
                        Spacer()
                        Text("••••••••").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    }
                    .contextMenu {
                        Button("Remove", role: .destructive) {
                            Keychain.delete(name: name, workspace: ws.id)
                            model.workspaces[i].envNames.removeAll { $0 == name }
                        }
                    }
                }
                Text("Stored in your Keychain. Never given to the chats Taki starts.")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 15)).foregroundStyle(Theme.secondary).frame(width: 58, alignment: .leading)
            content()
        }
    }

    private func changeFolder(_ i: Int) {
        guard let url = FolderPicker.choose(prompt: "Use folder", start: model.workspaces[i].folder).first else { return }
        model.workspaces[i].folder = url.path
        model.refreshFacts()
    }
}

struct AddEnvSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspaceID: UUID
    @State private var name = ""
    @State private var value = ""
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a variable").font(.system(size: 18, weight: .semibold))
            TextField("NAME", text: $name).font(Theme.mono)
            SecureField("Value", text: $value)
            if failed { Text("Could not save it to the Keychain.").foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let key = name.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
                    guard !key.isEmpty, let i = model.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
                    if Keychain.set(value, name: key, workspace: workspaceID) {
                        if !model.workspaces[i].envNames.contains(key) { model.workspaces[i].envNames.append(key) }
                        dismiss()
                    } else { failed = true }
                }
                .buttonStyle(.borderedProminent).disabled(name.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22).frame(width: 380)
    }
}
