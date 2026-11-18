import CoreslotKit
import SwiftUI

/// Docker Desktop's VM and its running containers, from `coreslot status --docker`.
struct DockerSection: View {
    let model: DockerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let vm = model.vm {
                Text(vm).font(.callout.weight(.semibold)).monospacedDigit()
            }
            if let note = model.note {
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.name).lineLimit(1).truncationMode(.middle)
                        Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text(row.usage).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            ForEach(model.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
