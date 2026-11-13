import AppKit
import SwiftUI

/// Reports whether the window that holds this view is on screen, from the window itself: a menu
/// bar panel that is hidden and shown again is followed as surely as one that is closed.
struct WindowVisibility: NSViewRepresentable {
    let changed: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> Probe { Probe(changed) }
    func updateNSView(_ view: Probe, context: Context) { view.changed = changed }

    final class Probe: NSView {
        var changed: @MainActor (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?

        init(_ changed: @escaping @MainActor (Bool) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification]
                observers = names.map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] n in
                        let closing = n.name == NSWindow.willCloseNotification
                        MainActor.assumeIsolated { self?.report(closing: closing) }
                    }
                }
            }
            report(closing: false)
        }

        private func report(closing: Bool) {
            let on = !closing && (window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false)
            guard on != last else { return }
            last = on
            changed(on)
        }
    }
}
