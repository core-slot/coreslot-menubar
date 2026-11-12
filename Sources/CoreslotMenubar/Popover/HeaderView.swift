import AppKit
import SwiftUI

struct HeaderView: View {
    let model: PopoverModel
    let openTimeline: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("coreslot").font(.headline)
                if let level = model.level {
                    HStack(spacing: 5) {
                        Circle().fill(dot).frame(width: 7, height: 7)
                        Text(level).font(.callout)
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer()
                Button(action: openTimeline) { Image(systemName: "chart.bar.xaxis") }
                    .buttonStyle(.borderless)
                    .help("Open the timeline")
                    .accessibilityLabel("Open the timeline")
                Menu {
                    Button("Settings…") {
                        openSettings()
                        NSApp.activate()
                    }
                    Button("About coreslot") {
                        NSApp.orderFrontStandardAboutPanel(nil)
                        NSApp.activate()
                    }
                    Divider()
                    Button("Quit coreslot") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }
            ForEach(model.notices, id: \.self) { notice in
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var dot: Color {
        switch model.tone {
        case .calm: .green
        case .tight: .yellow
        case .critical: .red
        case .unknown: .gray
        }
    }
}

struct FooterView: View {
    let totals: String?
    let openTimeline: () -> Void

    var body: some View {
        HStack {
            if let totals { Text(totals).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 8)
            Button("Timeline", action: openTimeline).controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
