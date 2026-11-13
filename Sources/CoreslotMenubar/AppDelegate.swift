import AppKit
import CoreslotKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store(feed: AppDelegate.feed())
    let loginItem = LoginItem()
    /// Set by the menu bar label, the one view that lives as long as the app.
    var openTimeline: (() -> Void)?

    private static func feed() -> Feed {
        #if DEBUG
        if let fixture = Present.fixtureFeed(CommandLine.arguments) { return fixture }
        #endif
        return .live
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        #if DEBUG
        Present.measureIfAsked(store: store)
        #endif
    }

    /// Opening the app from Finder or Spotlight while it runs: the menu bar extra may be hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showTimeline()
        return false
    }

    func showTimeline() {
        openTimeline?()
        NSApp.activate()
    }

    /// While the timeline is open the app has a Dock icon and a menu, like any app with a window.
    func timelineOpen(_ open: Bool) {
        NSApp.setActivationPolicy(open ? .regular : .accessory)
        if open { NSApp.activate() }
    }
}
