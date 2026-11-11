import AppKit
import SwiftUI

@main
struct TakiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window(Edition.name, id: "main") {
            MainView()
                .environment(delegate.model)
                .frame(minWidth: 1180, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.presented)        // the window always opens at launch, even if it was closed last time
        .defaultSize(width: 1460, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New terminal tab") { delegate.model.newTerminalTab() }.keyboardShortcut("t")
                Button("New Claude Code tab") { delegate.model.newTerminal(.claude, folder: delegate.model.currentTerminalFolder) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Close tab") { delegate.model.closeCurrentTerminal() }
                    .keyboardShortcut("w")
                    .disabled(delegate.model.section != .terminals || delegate.model.terminals.isEmpty)
            }
            CommandMenu("Tabs") {
                Button("Next tab") { delegate.model.cycleTerminal(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous tab") { delegate.model.cycleTerminal(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button(n == 9 ? "Last tab" : "Tab \(n)") { delegate.model.selectTerminal(number: n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")))
                }
            }
        }

        Settings {
            settings.frame(width: 860, height: 560)
                .background(LinearGradient(colors: [Theme.windowTop, Theme.windowBottom], startPoint: .top, endPoint: .bottom))
        }
    }
}

extension TakiApp {
    /// The Settings window's content.
    @ViewBuilder var settings: some View {
        SettingsView().environment(delegate.model)
    }
}

/// Owns the model and the menu bar item. The status item is AppKit so it can show the panel on a
/// left click and a menu with Open and Quit on a right click.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel

    override init() {
        ShellEnvironment.dropInheritedAgentMarkers()        // before any shell, chat or scan starts
        model = AppModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        Appearance.apply()
        TakiTerminalView.installShiftReturn()
        DispatchQueue.global(qos: .utility).async {
            TakiTerminalView.pruneDroppedImages()
            _ = AgentCLI.installed()          // reads the login PATH once, off the main thread
        }
        signal(SIGPIPE, SIG_IGN)     // a chat that dies mid-write must not take Taki down with it
        guard !TestHost.isActive else { return }
    }


    /// Taki Pro lives on in the menu bar when its window closes; the free edition has no menu bar
    /// item, so closing its window quits it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !Edition.isPro }

    /// Clicking the Dock icon with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openMain() }
        return true
    }

    /// Quitting stops every terminal and chat Taki runs: ask once when one of them is mid-task.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let warning = model.quitWarning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit \(Edition.name)?"
        alert.informativeText = "You have \(warning). Quitting stops them."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ note: Notification) {
        model.flushTerminalSave()                    // the last second of tab changes is not lost
    }


    func openMain() {
        NSApp.activate()
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            model.openMainWindow?()
        }
    }

}

/// Light, dark, or follow the Mac (default). Applied to the app, its windows and the menu bar panel.
@MainActor
enum Appearance {
    static var onChange: (() -> Void)?

    static func apply() {
        switch UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        onChange?()
    }
}
