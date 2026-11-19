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
                YouTubeSetPlaceholderView()
            case let .job(id):
                if let job = model.job(id: id) {
                    JobProgressView(job: job)
                } else {
                    ContentUnavailableView("Job not found", systemImage: "questionmark.folder")
                }
            }
        }
        .frame(minWidth: 820, minHeight: 520)
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

/// Replaced by the real YouTube Set flow in a later task.
struct YouTubeSetPlaceholderView: View {
    var body: some View {
        ContentUnavailableView("YouTube Set", systemImage: "waveform.badge.magnifyingglass",
                               description: Text("Identify every song in a mix and download them. Coming next."))
    }
}
