import SwiftUI
import GimmeCore

struct ActivityView: View {
    @EnvironmentObject var store: GimmeStore
    var body: some View {
        List(store.activity) { entry in
            VStack(alignment: .leading) {
                Text(entry.text)
                Text(entry.time.formatted(.dateTime)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Activity")
    }
}
