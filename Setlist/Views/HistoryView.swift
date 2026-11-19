import SwiftUI
import SetlistCore

/// One past job in the sidebar.
struct HistoryRow: View {
    let job: Job

    private var done: Int { job.tracks.filter { $0.status == .done }.count }
    private var failed: Int { job.tracks.filter { $0.status == .failed }.count }
    private var inProgress: Bool { job.tracks.contains { $0.status.isActive } }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if inProgress {
                ProgressView().controlSize(.mini)
            } else if failed > 0 {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
        }
    }

    private var icon: String {
        switch job.kind {
        case .pasteList: "text.alignleft"
        case .link: "link"
        case .youtubeSet: "waveform.badge.magnifyingglass"
        }
    }

    private var subtitle: String {
        var parts = ["\(done)/\(job.tracks.count) tracks"]
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }
}
