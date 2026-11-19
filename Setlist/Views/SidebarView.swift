import SwiftUI
import SetlistCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("New") {
                Label("Text", systemImage: "text.alignleft")
                    .tag(SidebarItem.text)
                Label("Link", systemImage: "link")
                    .tag(SidebarItem.link)
                Label("YouTube Set", systemImage: "waveform.badge.magnifyingglass")
                    .tag(SidebarItem.youtubeSet)
            }
            Section("History") {
                if model.jobs.isEmpty {
                    Text("No downloads yet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(model.jobs) { job in
                    HistoryRow(job: job)
                        .tag(SidebarItem.job(job.id))
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    model.reloadJobs()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload history from disk")
            }
        }
    }
}
