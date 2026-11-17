import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.library.isEmpty {
                    ContentUnavailableView {
                        Label("Your library is empty", systemImage: "books.vertical")
                    } description: {
                        Text("Tap the heart on any work to keep it here.")
                    }
                } else {
                    List(model.library) { item in
                        NavigationLink(value: WorkRoute(sourceID: item.sourceID, summary: item.work)) {
                            VStack(alignment: .leading) {
                                WorkRow(work: item.work)
                                if let position = model.position(sourceID: item.sourceID, workID: item.work.id) {
                                    Text("Last read: \(position.chapterTitle)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: WorkRoute.self) { WorkDetailView(route: $0) }
        }
    }
}
