import CoreslotKit
import SwiftUI

extension EnvironmentValues {
    /// Shows every row's hover actions at once, for looking at the popover without a pointer.
    @Entry var revealsRowActions = false
}

struct PopoverView: View {
    let store: Store
    let openTimeline: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Text("coreslot").font(.headline)
            switch store.reading {
            case .document(let doc, let notices)?: Text(Words.header(doc.watch, notices: notices))
            case .problem(let p)?: Text(String(describing: p))
            case nil: Text("Reading…")
            }
        }
        .padding()
        .frame(width: 400, alignment: .leading)
    }
}
