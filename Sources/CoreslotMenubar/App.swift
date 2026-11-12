import CoreslotKit
import SwiftUI

@main
enum Main {
    static func main() {
        #if DEBUG
        if Present.runIfAsked(CommandLine.arguments) { return }
        #endif
        CoreslotApp.main()
    }
}

struct CoreslotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: delegate.store, openTimeline: delegate.showTimeline)
                .background(WindowVisibility { delegate.store.setVisible(.popover, $0) })
        } label: {
            MenuBarLabel(store: delegate.store, delegate: delegate)
        }
        .menuBarExtraStyle(.window)

        Window("Timeline", id: "timeline") {
            TimelinePlaceholder()
                .background(WindowVisibility { delegate.store.setVisible(.timeline, $0) })
                .onAppear { delegate.timelineOpen(true) }
                .onDisappear { delegate.timelineOpen(false) }
        }
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsPlaceholder()
        }
    }
}

private struct MenuBarLabel: View {
    let store: Store
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image(for: store.icon))
            .accessibilityLabel(MenuBarIcon.words(store.icon))
            .onAppear { delegate.openTimeline = { openWindow(id: "timeline") } }
    }
}

/// The timeline window's place until its charts exist.
struct TimelinePlaceholder: View {
    var body: some View {
        Text("The timeline is not built yet.")
            .foregroundStyle(.secondary)
            .frame(minWidth: 640, minHeight: 400)
    }
}

struct SettingsPlaceholder: View {
    var body: some View {
        Text("No settings yet.")
            .foregroundStyle(.secondary)
            .frame(width: 360, height: 120)
    }
}
