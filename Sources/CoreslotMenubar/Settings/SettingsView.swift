import AppKit
import CoreslotKit
import SwiftUI
import UniformTypeIdentifiers

/// The coreslot in use and another to choose, a state directory for development, and launch at
/// login as the system has it.
struct SettingsView: View {
    let store: Store
    let loginItem: LoginItem

    var body: some View {
        Form {
            BinarySection(store: store)
            StateDirSection(store: store)
            Section { LoginItemRow(item: loginItem) }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: loginItem.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }
}

private struct BinarySection: View {
    let store: Store
    @State private var choosing = false

    var body: some View {
        Section("coreslot") {
            LabeledContent("In use") {
                Text(store.binary.map { SafeText.display($0.url.path) } ?? "None")
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            if let binary = store.binary {
                LabeledContent("Version", value: binary.version.description)
            }
            LabeledContent("Oldest supported", value: Version.minimum.description)
            if store.binary == nil {
                Text(store.chosenBinary == nil
                    ? "None was found in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin or the app's PATH."
                    : "The chosen file did not answer as coreslot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if store.chosenBinary != nil {
                    Button("Use the one found") { store.choose(binary: nil) }
                }
                Spacer()
                Button("Choose another…") { choosing = true }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result { store.choose(binary: url) }
            }
            .fileDialogDefaultDirectory(store.binary?.url.deletingLastPathComponent())
            .fileDialogBrowserOptions(.includeHiddenFiles)
        }
    }
}

private struct StateDirSection: View {
    let store: Store
    @State private var choosing = false

    var body: some View {
        Section {
            LabeledContent("Reading") {
                Text(store.document.map { SafeText.display($0.stateDir) } ?? "Not read yet")
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            Text(store.chosenStateDir == nil
                ? "The one coreslot uses. For development, another directory is a budget of its own."
                : "Chosen, and passed to coreslot as CORESLOT_STATE_DIR.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if store.chosenStateDir != nil {
                    Button("Use coreslot's own") { store.choose(stateDir: nil) }
                }
                Spacer()
                Button("Choose another…") { choosing = true }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { store.choose(stateDir: url) }
            }
            .fileDialogBrowserOptions(.includeHiddenFiles)
        } header: {
            Text("State directory")
        }
    }
}

/// The toggle shows the service's own status; it is not offered outside /Applications.
private struct LoginItemRow: View {
    let item: LoginItem

    var body: some View {
        if item.state == .notOffered {
            LabeledContent("Launch at login") {
                Text("Offered when coreslot runs from /Applications")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        } else {
            Toggle("Launch at login", isOn: Binding(
                get: { item.state == .enabled || item.state == .requiresApproval },
                set: { item.set($0) }))
            Text(words)
                .font(.caption)
                .foregroundStyle(.secondary)
            if item.state == .requiresApproval {
                Button("Open Login Items…", action: item.openSystemSettings)
            }
            if let failure = item.failure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var words: String {
        switch item.state {
        case .enabled: "On: coreslot opens when you log in."
        case .requiresApproval: "Waiting for your approval in System Settings, under Login Items."
        case .notRegistered: "Off."
        case .notFound, .notOffered: "The system cannot find this copy of coreslot to open at login."
        }
    }
}
