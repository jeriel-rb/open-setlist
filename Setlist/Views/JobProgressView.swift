import SwiftUI
import SetlistCore

struct JobProgressView: View {
    @Environment(AppModel.self) private var model
    let job: Job

    private var done: Int { job.tracks.filter { $0.status == .done }.count }
    private var finished: Int { job.tracks.filter { [.done, .failed, .skipped].contains($0.status) }.count }
    private var failed: Int { job.tracks.filter { $0.status == .failed }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.name).font(.title2.weight(.semibold))
                    Text(summary).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.revealInFinder(job)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }

            ProgressView(value: Double(finished), total: Double(max(job.tracks.count, 1)))

            Table(job.tracks) {
                TableColumn("") { track in
                    StatusIcon(status: track.status)
                }
                .width(22)
                TableColumn("#") { track in
                    Text(String(format: "%02d", track.index)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(32)
                TableColumn("Time") { track in
                    Text(track.start.map(JobStore.timestamp) ?? "").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(job.kind == .youtubeSet ? 64 : 0)
                TableColumn("Track") { track in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.query).lineLimit(1)
                        if let note = track.note, !note.isEmpty {
                            Text(note).font(.caption).foregroundStyle(track.status == .failed ? .red : .secondary).lineLimit(1)
                        }
                    }
                }
                TableColumn("Match") { track in
                    ConfidenceBadge(confidence: track.confidence, note: track.note)
                }
                .width(130)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
        .padding(20)
        .navigationTitle(job.name)
    }

    private var summary: String {
        var parts = ["\(done) of \(job.tracks.count) downloaded"]
        if failed > 0 { parts.append("\(failed) failed") }
        if let dir = model.directory(of: job) { parts.append(dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
        return parts.joined(separator: " · ")
    }
}

struct StatusIcon: View {
    let status: TrackStatus

    var body: some View {
        switch status {
        case .pending: Image(systemName: "clock").foregroundStyle(.secondary)
        case .searching: Image(systemName: "magnifyingglass").foregroundStyle(.blue)
        case .downloading: Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
