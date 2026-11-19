import SwiftUI
import SetlistCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .help("Theme, file names, download folder and more (⌘,)")
                    Button {
                        openWindow(id: HelpCommands.windowID)
                    } label: {
                        Label("Help", systemImage: "questionmark.circle")
                            .labelStyle(.iconOnly)
                            .contentShape(Rectangle())
                    }
                    .help("What the screens, marks and tags mean (⌘?)")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
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
    }
}
