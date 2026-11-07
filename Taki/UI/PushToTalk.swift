import AppKit
import Carbon.HIToolbox
import Observation

/// Hold Right Option in a Taki terminal to dictate; let go to type what you said into that tab's
/// prompt (no Return is sent). Any other key while holding cancels it, so Option shortcuts keep
/// working. The mic button in the Terminals toolbar does the same with a click.
@MainActor
@Observable
final class PushToTalk {
    static let shared = PushToTalk()
    static let enabledKey = "holdToDictate"

    let dictation = VoiceDictation()
    /// The tab the text goes to: the terminal that was focused when dictation started.
    @ObservationIgnored private weak var target: TakiTerminalView?
    @ObservationIgnored private var pendingStart: DispatchWorkItem?
    @ObservationIgnored private var monitors: [Any] = []
    /// Started by holding the key (another key then cancels), not by the toolbar button.
    @ObservationIgnored private var viaHold = false

    /// How long Right Option must be held alone before listening starts (a quick tap does nothing).
    static let holdDelay: TimeInterval = 0.25
    static let rightOptionKeyCode = UInt16(kVK_RightOption)

    private var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    func install() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            self?.flagsChanged(e); return e
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            self?.cancelHold(); return e
        }) { monitors.append(m) }
        // Switching apps while holding the key means its release never reaches Taki: stop then,
        // so the microphone is never left open.
        monitors.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelHold() }
        })
    }

    /// The toolbar button: start listening into the current terminal, or stop and type the text.
    func toggle(into view: TakiTerminalView?) {
        guard !dictation.isFinishing else { return }
        if dictation.isActive {
            stopAndType()
        } else if let view {
            begin(into: view, viaHold: false)
        } else {
            dictation.showProblem("Open a terminal tab first, then dictate into it.")
        }
    }

    private func flagsChanged(_ event: NSEvent) {
        guard event.keyCode == Self.rightOptionKeyCode else { return }
        let held = Self.rightOptionDown(event.modifierFlags)
        if held {
            guard enabled, Self.isAlone(event.modifierFlags), !dictation.isBusy,
                  let view = event.window?.firstResponder as? TakiTerminalView else { return }
            let item = DispatchWorkItem { [weak self, weak view] in
                guard let self, let view else { return }
                self.pendingStart = nil
                self.begin(into: view, viaHold: true)
            }
            pendingStart?.cancel()
            pendingStart = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: item)
        } else {
            pendingStart?.cancel()
            pendingStart = nil
            if dictation.isActive, viaHold { stopAndType() }
        }
    }

    /// Another key while holding (an Option shortcut), or Taki losing focus: drop the hold.
    private func cancelHold() {
        pendingStart?.cancel()
        pendingStart = nil
        if dictation.isActive, viaHold { dictation.cancel(); target = nil; viaHold = false }
    }

    private func begin(into view: TakiTerminalView, viaHold: Bool) {
        guard !dictation.isBusy else { return }
        target = view
        self.viaHold = viaHold
        Task { await dictation.start() }
    }

    private func stopAndType() {
        let view = target
        target = nil
        viaHold = false
        Task {
            let text = await dictation.finish()
            guard let view, !text.isEmpty else { return }
            view.send(txt: text)
            view.window?.makeFirstResponder(view)
        }
    }

    /// The right Option key itself is down (its own device bit, so the left Option key held at the
    /// same time never looks like a second press).
    nonisolated static func rightOptionDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.rawValue & rightOptionDeviceMask != 0
    }

    /// NX_DEVICERALTKEYMASK from IOKit's IOLLEvent.h.
    nonisolated static let rightOptionDeviceMask: UInt = 0x40

    /// Option is the only modifier held (Shift, Command, Control or Fn mean another shortcut).
    nonisolated static func isAlone(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.shift, .command, .control, .option, .function]) == .option
    }
}
