import SwiftUI

/// A workspace's dev commands: status dot, name, command, memory, port, start or stop.
struct ServicesCard: View {
    @Environment(AppModel.self) private var model
    let workspaceID: UUID
    @State private var adding = false
    @State private var hovered: UUID?

    var body: some View {
        if let ws = model.workspaces.first(where: { $0.id == workspaceID }) {
            let running = ws.services.filter { model.runner.isRunning($0) }.count
                + model.externalServers(in: ws).count + model.containers(in: ws).count
            Card("Services", badge: "\(running) running") {
                LinkButton("+ Add") { adding = true }
            } content: {
                if ws.services.isEmpty {
                    Text("Add the command that runs this project, like pnpm dev.")
                        .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                }
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(ws.services) { s in row(s, ws: ws) }
                        ForEach(model.externalServers(in: ws)) { s in
                            outsideRow(name: s.command, detail: "Started outside Taki" + (s.startedAt.map { " · since \(Format.clock($0))" } ?? ""),
                                       memory: s.memoryBytes, port: s.port, logo: nil)
                        }
                        ForEach(model.containers(in: ws)) { c in
                            outsideRow(name: c.shortName, detail: "Docker · \(c.status)", memory: nil, port: c.ports.first,
                                       logo: Brand.logo(forImage: c.image) ?? "docker")
                        }
                    }
                }
                .padding(.horizontal, -6)
            }
            .sheet(isPresented: $adding) { AddServiceSheet(workspaceID: workspaceID) }
        }
    }

    /// A server or container running here that Taki did not start: shown, not controlled.
    private func outsideRow(name: String, detail: String, memory: UInt64?, port: Int?, logo: String?) -> some View {
        HStack(spacing: 14) {
            if let logo { WorkspaceBadge(symbol: "shippingbox", name: name, logo: logo, size: 18) } else { StatusDot(color: Theme.live) }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let memory { Text(Format.bytesText(memory)).font(.system(size: 14).monospacedDigit()).foregroundStyle(Theme.secondary) }
            if let port {
                Button { if let u = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(u) } } label: {
                    Text(verbatim: ":\(port)").font(.system(size: 15, weight: .medium, design: .monospaced)).foregroundStyle(Theme.link)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func row(_ s: Workspace.Service, ws: Workspace) -> some View {
        let on = model.runner.isRunning(s)
        return HStack(spacing: 14) {
            StatusDot(color: on ? Theme.live : Theme.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.system(size: 15, weight: .medium))
                Text(s.command).font(Theme.mono).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
            }
            Spacer(minLength: 8)
            if on {
                Text(Format.bytesText(model.serviceMemory[s.id] ?? 0)).font(.system(size: 14).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
            if let port = model.servicePorts[s.id] ?? s.port {
                Button { if let u = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(u) } } label: {
                    Text(verbatim: ":\(port)").font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(on ? Theme.link : Theme.tertiary)
                }
                .buttonStyle(.plain).help("Open in the browser")
            }
            if hovered == s.id || !on {
                Button { on ? model.runner.stop(s) : model.runner.start(s, in: ws) } label: {
                    Image(systemName: on ? "stop.fill" : "play.fill").font(.system(size: 12))
                        .foregroundStyle(Theme.secondary).frame(width: 18)
                }
                .buttonStyle(.plain).help(on ? "Stop" : "Start")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(on ? Theme.selection : .clear, in: .rect(cornerRadius: 12, style: .continuous))
        .onHover { hovered = $0 ? s.id : (hovered == s.id ? nil : hovered) }
        .contextMenu {
            Button(on ? "Stop" : "Start") { on ? model.runner.stop(s) : model.runner.start(s, in: ws) }
            Divider()
            Button("Remove service", role: .destructive) {
                model.runner.stop(s)
                if let i = model.workspaces.firstIndex(where: { $0.id == ws.id }) {
                    model.workspaces[i].services.removeAll { $0.id == s.id }
                }
            }
        }
    }
}

struct AddServiceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspaceID: UUID
    @State private var name = ""
    @State private var command = ""
    @State private var port = ""

    private var portValue: Int? { Int(port).flatMap { (1...65_535).contains($0) ? $0 : nil } }
    private var portInvalid: Bool { !port.isEmpty && portValue == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a service").font(.system(size: 18, weight: .semibold))
            TextField("Name, like web", text: $name)
            TextField("Command, like pnpm dev", text: $command).font(Theme.mono)
            TextField("Port, optional", text: $port)
            if portInvalid { Text("A port is a number from 1 to 65535.").font(.caption).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    guard let i = model.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
                    let cmd = command.trimmingCharacters(in: .whitespaces)
                    let fallback = cmd.split(separator: " ").last.map(String.init) ?? "service"
                    model.workspaces[i].services.append(.init(name: name.isEmpty ? fallback : name, command: cmd, port: portValue))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty || portInvalid)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22).frame(width: 380)
    }
}
