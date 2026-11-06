import AppKit
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let palette = Self("palette", default: .init(.space, modifiers: [.option]))
}

@main
struct TakiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Taki", id: "main") {
            MainView()
                .environment(delegate.model)
                .frame(minWidth: 1180, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.presented)        // the window always opens at launch, even if it was closed last time
        .defaultSize(width: 1460, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New chat") { delegate.model.newChatInLastFolder() }.keyboardShortcut("n")
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
            SettingsView().environment(delegate.model).frame(width: 860, height: 560)
                .background(LinearGradient(colors: [Theme.windowTop, Theme.windowBottom], startPoint: .top, endPoint: .bottom))
        }
    }
}

/// Owns the model and the menu bar item. The status item is AppKit so it can show the panel on a
/// left click and a menu with Open and Quit on a right click.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var palette: PaletteWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        Appearance.apply()
        signal(SIGPIPE, SIG_IGN)     // a chat that dies mid-write must not take Taki down with it
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "water.waves", accessibilityDescription: "Taki")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        popover.behavior = .transient
        popover.contentSize = NSSize(width: MenuPanel.width, height: 760)
        Appearance.onChange = { [weak self] in self?.popover.appearance = NSApp.appearance }
        popover.appearance = NSApp.appearance
        let host = NSHostingController(rootView: MenuPanel(openMain: { [weak self] in self?.openMain() }).environment(model))
        host.sizingOptions = .preferredContentSize       // the popover follows the panel's real size
        popover.contentViewController = host
        KeyboardShortcuts.onKeyUp(for: .palette) { [weak self] in self?.togglePalette() }
        Notifier.shared.requestOnce()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openMain() }
        return true
    }

    /// Quitting stops every terminal and chat Taki runs: ask once when one of them is mid-task.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let warning = model.quitWarning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Taki?"
        alert.informativeText = "You have \(warning). Quitting stops them."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ note: Notification) {
        model.flushTerminalSave()                    // the last second of tab changes is not lost
        model.runner.stopAll()
        for chat in model.chats { chat.stop() }
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Open Taki", action: #selector(openMainAction), keyEquivalent: "o").target = self
            menu.addItem(withTitle: model.paused ? "Resume updates" : "Pause updates",
                         action: #selector(togglePause), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Taki", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
            return
        }
        if popover.isShown { popover.performClose(nil) } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func openMainAction() { openMain() }
    @objc private func togglePause() { model.paused.toggle() }

    func openMain() {
        popover.performClose(nil)
        NSApp.activate()
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            model.openMainWindow?()
        }
    }

    private func togglePalette() {
        if let p = palette, p.isVisible { p.close(); return }
        let p = PaletteWindow(model: model) { [weak self] in self?.openMain() }
        palette = p
        p.present()
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
