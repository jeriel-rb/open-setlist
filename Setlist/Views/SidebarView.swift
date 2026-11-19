import SwiftUI
import SetlistCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// The history row being renamed in place.
    @State private var renamingID: UUID?
    @State private var jobToTrash: Job?

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
                    HistoryRow(job: job, isRenaming: renamingID == job.id) { newName in
                        if let newName { model.rename(job, to: newName) }
                        renamingID = nil
                    }
                    .tag(SidebarItem.job(job.id))
                    .contextMenu {
                        Button("Rename") { renamingID = job.id }
                        Button("Show in Finder") { model.revealInFinder(job) }
                        if !model.isRunning(job), job.retryableCount > 0 {
                            Button("Retry \(job.retryableCount) Failed") { model.retry(job) }
                        }
                        Divider()
                        Button("Move to Trash…", role: .destructive) { jobToTrash = job }
                            .disabled(model.isRunning(job))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if case let .job(id) = model.selection, let job = model.job(id: id), !model.isRunning(job) {
                jobToTrash = job
            }
        }
        .confirmationDialog(
            "Move “\(jobToTrash?.name ?? "")” to the Trash?",
            isPresented: Binding(get: { jobToTrash != nil }, set: { if !$0 { jobToTrash = nil } }),
            presenting: jobToTrash
        ) { job in
            Button("Move to Trash", role: .destructive) { model.moveToTrash(job) }
        } message: { job in
            Text("The folder \(model.directory(of: job)?.tildePath ?? job.name) and the songs in it go to the Trash. You can put them back from there.")
        }
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
