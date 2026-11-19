import SwiftUI
import SetlistCore

/// One past job in the sidebar. Its Rename menu item edits the name in place.
/// (A double-click gesture on the row would swallow the single click that selects it.)
struct HistoryRow: View {
    let job: Job
    var isRenaming = false
    /// Called when an in-place rename ends: the new name, or nil when it was cancelled.
    var onRenameEnded: (String?) -> Void = { _ in }

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var done: Int { job.tracks.filter { $0.status == .done }.count }
    private var failed: Int { job.tracks.filter { $0.status == .failed }.count }
    private var inProgress: Bool { job.hasActiveTracks }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Job name", text: $draft)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                        .onSubmit { fieldFocused = false }
                        .onExitCommand {
                            draft = job.name
                            fieldFocused = false
                        }
                        .onChange(of: fieldFocused) { _, focused in if !focused { finish() } }
                        .onAppear {
                            draft = job.name
                            fieldFocused = true
                        }
                } else {
                    Text(job.name).lineLimit(1)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if inProgress {
                ProgressView().controlSize(.mini)
            } else if job.retryableCount > 0 {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
        }
    }

    private func finish() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        onRenameEnded(name.isEmpty || name == job.name ? nil : name)
    }

    private var icon: String {
        switch job.kind {
        case .pasteList: "text.alignleft"
        case .link: "link"
        case .youtubeSet: "waveform.badge.magnifyingglass"
        }
    }

    private var subtitle: String {
        let cancelled = job.retryableCount - failed
        var parts = ["\(done)/\(job.tracks.count) tracks"]
        if failed > 0 { parts.append("\(failed) failed") }
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        return parts.joined(separator: " · ")
    }
}
