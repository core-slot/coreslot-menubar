import Foundation
import Observation
import ServiceManagement

/// Launch at login through `SMAppService.mainApp`. What Settings shows is the service's own
/// status, read again whenever it is looked at, never a stored preference. It is offered only to
/// a copy that runs from /Applications, where an install puts it.
@MainActor @Observable
final class LoginItem {
    enum State: Equatable { case notOffered, enabled, requiresApproval, notRegistered, notFound }

    private(set) var state: State = .notOffered
    /// Why the last change failed, as the system says it.
    private(set) var failure: String?
    @ObservationIgnored private let shown: State?

    init() {
        shown = nil
        refresh()
    }

    #if DEBUG
    /// Shows `state` and changes nothing: `--present` only.
    init(showing state: State) {
        (shown, self.state) = (state, state)
    }
    #endif

    static var offered: Bool {
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath()
        return app.pathExtension == "app" && app.deletingLastPathComponent().path == "/Applications"
    }

    func refresh() {
        if let shown { return state = shown }
        guard Self.offered else { return state = .notOffered }
        state = switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        default: .notFound
        }
    }

    func set(_ on: Bool) {
        guard shown == nil, Self.offered else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
