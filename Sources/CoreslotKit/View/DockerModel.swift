import Foundation

/// The popover's Docker section as text: the VM line, a row per container, and a note when there
/// is no figure to show. An engine's strings go through `SafeText`.
package struct DockerModel: Equatable, Sendable {
    package struct Row: Equatable, Sendable, Identifiable {
        package var id: String { fullID }
        let fullID: String
        package let name: String
        /// The image, and the Compose project when it has one.
        package let detail: String
        package let usage: String
    }

    package var vm: String?
    package var rows: [Row] = []
    package var note: String?
    package var warnings: [String] = []

    /// Nothing was asked for, or the coreslot does not know `--docker`: the section is not drawn.
    package var isEmpty: Bool { vm == nil && rows.isEmpty && note == nil && warnings.isEmpty }

    package init(_ reading: DockerReading?) {
        switch reading {
        case nil, .absent?, .unsupported?: return
        case .problem(let p)?: note = Words.problem(p, command: "status --docker").state
        case .section(let s)?:
            warnings = s.warnings.map(SafeText.display)
            guard s.state == "ok" else {
                note = Words.docker(state: s.state, reason: s.reason)
                return
            }
            var parts = s.vm.memMiB.map { ["Docker VM " + Formatting.size($0)] } ?? ["Docker VM"]
            if s.vm.identified, let f = s.vm.footprintMiB { parts.append("VM process " + Formatting.size(f)) }
            if let free = s.freeEstMiB { parts.append("about " + Formatting.size(free) + " free") }
            vm = parts.joined(separator: " · ")
            rows = s.containers.map {
                Row(fullID: $0.id, name: SafeText.display($0.name),
                    detail: ([$0.image] + ($0.project.isEmpty ? [] : [$0.project])).map(SafeText.display).joined(separator: " · "),
                    usage: "\(Formatting.size($0.usageMiB)) of \(Formatting.size($0.limitMiB))")
            }
            if rows.isEmpty { note = "No containers running" }
        }
    }
}

extension Words {
    /// What a `docker.state` other than `ok` says, with its `reason` where it has one.
    package static func docker(state: String, reason: String) -> String {
        switch (state, reason) {
        case ("not_running", _): "Docker Desktop is not running"
        case ("other_engine", _): "Another Docker engine is running: there is no Docker Desktop VM to show"
        case ("off", "platform"): "Docker reading is not available on this platform"
        case ("off", "config"): "Docker reading is turned off in coreslot's configuration"
        case ("off", "nested"): "Docker reading is off: coreslot is running inside a container"
        case ("off", "state-dir"): "Docker reading is off: coreslot's state directory is not the machine's own"
        case ("off", "remote-host"): "Docker reading is off: DOCKER_HOST points at a remote engine"
        case ("off", let r): "Docker reading is off" + (r.isEmpty ? "" : " (\(SafeText.display(r)))")
        case ("no_reading", "deadline"): "Docker did not answer in time"
        case ("no_reading", "parse"): "Docker's answer could not be read"
        case ("no_reading", let r): "Docker could not be read" + (r.isEmpty ? "" : " (\(SafeText.display(r)))")
        case (let s, _): "Docker state " + SafeText.display(s)
        }
    }
}
