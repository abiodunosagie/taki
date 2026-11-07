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
    @AppStorage("notifyOverlaps") private var notifyOverlaps = true
    @AppStorage("notifyWaiting") private var notifyWaiting = true
    @AppStorage("notifyFinished") private var notifyFinished = true
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
                        }
                        Card(Edition.name, fill: false) {
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
        .scrollEdgeEffectStyle(.soft, for: .top)
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
