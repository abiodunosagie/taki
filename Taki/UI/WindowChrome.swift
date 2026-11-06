import AppKit
import SwiftUI

/// Places the system's close, minimize and zoom buttons inside the floating sidebar panel with
/// room around them (as Chrome and Finder lower theirs), instead of
/// hugging the window's top corner. They stay the system's own buttons, with their glass and
/// hover glyphs; only their position changes. Applied again on every layout pass and after a
/// resize, full screen, minimize or key change, because AppKit lays them out again then.
struct WindowChrome: NSViewRepresentable {
    /// Gap from the panel's left edge to the close button, and the height of the band the buttons
    /// are centered in, both from the window's top left corner.
    static let buttonsLeft: CGFloat = MainView.panelInset + 14
    static let bandHeight: CGFloat = MainView.panelInset * 2 + 40
    static let spacing: CGFloat = 20          // center to center, as the system spaces them
    /// Half the height of a system window button (they are 14 pt tall).
    static let buttonHalfHeight: CGFloat = 7
    /// Where the buttons end, from the top of the window: the sidebar's rows start below this.
    static var buttonsBottom: CGFloat { bandHeight / 2 + buttonHalfHeight }
    /// Air between the buttons and the first sidebar row.
    static let rowsGap: CGFloat = 14

    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? ChromeView)?.place() }

    final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard let w = window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                         NSWindow.didExitFullScreenNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didChangeBackingPropertiesNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.place()
                        // After full screen AppKit rebuilds the title bar a moment later; place again then.
                        DispatchQueue.main.async { self?.place() }
                    }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.place() }
        }

        override func layout() {
            super.layout()
            place()
        }

        private func removeObservers() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        func place() {
            guard let w = window, !w.styleMask.contains(.fullScreen),
                  let close = w.standardWindowButton(.closeButton),
                  let titlebar = close.superview, let container = titlebar.superview else { return }
            let band = WindowChrome.bandHeight
            // The title bar strip the buttons live in: as tall as the band, pinned to the top.
            var frame = container.frame
            if frame.height != band || frame.origin.y != w.frame.height - band {
                frame.size.height = band
                frame.origin.y = w.frame.height - band
                container.frame = frame
                titlebar.frame = container.bounds
            }
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (i, type) in buttons.enumerated() {
                guard let b = w.standardWindowButton(type) else { continue }
                let origin = NSPoint(x: WindowChrome.buttonsLeft + CGFloat(i) * WindowChrome.spacing,
                                     y: ((band - b.frame.height) / 2).rounded())
                if b.frame.origin != origin { b.setFrameOrigin(origin) }
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { removeObservers() }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
