import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// Settings, built from the same flat cards as every screen: a label column and a control column.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("chatModel") private var chatModel = ""
    @AppStorage("permissionMode") private var permissionMode = ""
    @AppStorage("editor") private var editor = EditorChoice.finder.rawValue
    @AppStorage("notifyServers") private var notifyServers = true
    @AppStorage("notifyLimits") private var notifyLimits = true
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("shortLinks") private var shortLinks = true
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.gutter) {
                Text("Settings").font(.system(size: 20, weight: .semibold)).padding(.top, 4).padding(.bottom, 4)
                HStack(alignment: .top, spacing: Theme.gutter) {
                    VStack(spacing: Theme.gutter) {
                        Card("Claude", fill: false) {
                            row("Model", "New chats and Claude tabs use it.") {
                                Picker("", selection: $chatModel) {
                                    Text("Claude Code default").tag("")
                                    Text("Opus").tag("opus")
                                    Text("Sonnet").tag("sonnet")
                                    Text("Haiku").tag("haiku")
                                }
                                .labelsHidden().fixedSize()
                            }
                            divider
                            row("Permissions", "Your Claude Code settings, hooks, skills and CLAUDE.md always apply.") {
                                Picker("", selection: $permissionMode) {
                                    Text("My Claude Code setting").tag("")
                                    Text("Ask before edits and commands").tag("default")
                                    Text("Allow edits, ask for commands").tag("acceptEdits")
                                    Text("Plan only").tag("plan")
                                    Text("Never ask").tag("bypassPermissions")
                                }
                                .labelsHidden().fixedSize()
                            }
                        }
                        Card("Workspaces", fill: false) {
                            row("Short links", "name.localhost with no port. Only this Mac can open them.") {
                                Toggle("", isOn: $shortLinks).labelsHidden().toggleStyle(.switch).tint(Theme.live)
                                    .onChange(of: shortLinks) { _, on in on ? LocalProxy.shared.start() : LocalProxy.shared.stop() }
                            }
                            divider
                            row("Folder opens in", "For \"Open folder\" in a workspace.") {
                                Picker("", selection: $editor) {
                                    ForEach(EditorChoice.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
                                }
                                .labelsHidden().fixedSize()
                            }
                        }
                    }
                    VStack(spacing: Theme.gutter) {
                        Card("Look", fill: false) {
                            row("Appearance", "") {
                                Picker("", selection: $appearance) {
                                    Text("Match my Mac").tag("system")
                                    Text("Light").tag("light")
                                    Text("Dark").tag("dark")
                                }
                                .pickerStyle(.segmented).labelsHidden().fixedSize()
                                .onChange(of: appearance) { Appearance.apply() }
                            }
                            divider
                            row("Command palette", "Open, restart or stop anything from any app.") {
                                KeyboardShortcuts.Recorder("", name: .palette)
                            }
                        }
                        Card("Alerts", fill: false) {
                            row("Server left running", "Once, after two hours.") {
                                Toggle("", isOn: $notifyServers).labelsHidden().toggleStyle(.switch).tint(Theme.live)
                            }
                            divider
                            row("Claude limit nearly used", "Once per window, at 90%.") {
                                Toggle("", isOn: $notifyLimits).labelsHidden().toggleStyle(.switch).tint(Theme.live)
                            }
                        }
                        Card("Taki", fill: false) {
                            row("Open at login", "No account and no analytics. Nothing leaves this Mac.") {
                                Toggle("", isOn: $loginItem).labelsHidden().toggleStyle(.switch).tint(Theme.live)
                                    .onChange(of: loginItem) { _, on in
                                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                                        catch { loginItem = SMAppService.mainApp.status == .enabled }
                                    }
                            }
                            divider
                            HStack {
                                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                                    .font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                                Spacer()
                                PillButton(title: "Quit Taki") { NSApp.terminate(nil) }
                            }
                        }
                    }
                }
            }
            .screenPadding()
        }
    }

    private var divider: some View { Divider().opacity(0.35) }

    private func row<Control: View>(_ title: String, _ note: String, @ViewBuilder _ control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                if !note.isEmpty { Text(note).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control()
        }
    }
}
