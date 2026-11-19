import SwiftUI
import SetlistCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            switch model.selection {
            case .text, .none:
                PasteListView()
            case .link:
                LinkView()
            case .youtubeSet:
                YouTubeSetView()
            case let .job(id):
                if let job = model.job(id: id) {
                    // One view per job, so a half-typed title never carries over to the next job you open.
                    JobProgressView(job: job)
                        .id(job.id)
                } else {
                    ContentUnavailableView("Job not found", systemImage: "questionmark.folder")
                }
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear { model.applyAppearance() }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
