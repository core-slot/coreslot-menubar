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
    /// "+N more" under the rows past `shown`.
    package var more: String?
    package var warnings: [String] = []

    /// The most containers drawn, the biggest by usage first.
    package static let shown = 8

    /// Nothing was asked for, the coreslot does not know `--docker`, or Docker reading is `off`
    /// (turned off, or not for this machine): the section is not drawn.
    package var isEmpty: Bool { vm == nil && rows.isEmpty && note == nil && warnings.isEmpty }

    package init(_ reading: DockerReading?) {
        switch reading {
        case nil, .unsupported?: return
        case .problem(let p)?: note = Words.problem(p, command: "status --docker").state
        case .section(let s)?:
            warnings = s.warnings.map(SafeText.display)
            guard s.state == "ok" else {
                if s.state != "off" { note = Words.docker(state: s.state, reason: s.reason) }
                return
            }
            var parts = s.vm.memMiB.map { ["Docker VM " + Formatting.size($0)] } ?? ["Docker VM"]
            if s.vm.identified, let f = s.vm.footprintMiB { parts.append("VM process " + Formatting.size(f)) }
            if let free = s.freeEstMiB { parts.append("about " + Formatting.size(free) + " free") }
            vm = parts.joined(separator: " · ")
            let biggest = s.containers.sorted { ($0.usageMiB, $1.name) > ($1.usageMiB, $0.name) }
            rows = biggest.prefix(Self.shown).map {
                Row(fullID: $0.id, name: SafeText.display($0.name),
                    detail: ([$0.image] + ($0.project.isEmpty ? [] : [$0.project])).map(SafeText.display).joined(separator: " · "),
                    usage: "\(Formatting.size($0.usageMiB)) of \(Formatting.size($0.limitMiB))")
            }
            if biggest.count > Self.shown { more = "+\(biggest.count - Self.shown) more" }
            if rows.isEmpty { note = "No containers running" }
        }
    }
}

extension Words {
    /// What a `docker.state` other than `ok` says, with its `reason` where it has one.
    package static func docker(state: String, reason: String) -> String {
        switch (state, reason) {
        // coreslot finds only Docker Desktop's VM on the Apple hypervisor, so Docker on Docker VMM reads as this too.
        case ("not_running", _): "No Docker Desktop VM on the Apple hypervisor is running. Docker VMM, OrbStack and Colima are not read"
        case ("other_engine", _): "Another Docker engine is running: there is no Docker Desktop VM to show"
        case ("no_reading", "deadline"): "Docker did not answer in time"
        case ("no_reading", "parse"): "Docker's answer could not be read"
        case ("no_reading", let r): "Docker could not be read" + (r.isEmpty ? "" : " (\(SafeText.display(r)))")
        case (let s, _): "Docker state " + SafeText.display(s)
        }
    }
}
