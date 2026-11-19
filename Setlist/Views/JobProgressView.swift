import SwiftUI
import SetlistCore

struct JobProgressView: View {
    @Environment(AppModel.self) private var model
    let job: Job
    @State private var title = ""
    @State private var titleHovered = false
    @FocusState private var titleFocused: Bool

    private var done: Int { job.tracks.filter { $0.status == .done }.count }
    private var finished: Int { job.tracks.filter { !$0.status.isActive }.count }
    private var failed: Int { job.tracks.filter { $0.status == .failed }.count }
    private var cancelled: Int { job.tracks.filter { $0.status == .cancelled }.count }
    private var running: Bool { model.isRunning(job) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Job name", text: $title)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .focused($titleFocused)
                        .onSubmit { titleFocused = false }
                        .onExitCommand {
                            title = job.name
                            titleFocused = false
                        }
                        .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                        .padding(.horizontal, Self.titleInset)
                        .padding(.vertical, 3)
                        .background(titleFocused ? Color(nsColor: .textBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            // The outline is what tells you the title is a field: faint on hover, accent while editing.
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(titleFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                              lineWidth: titleFocused ? 2 : 1)
                                .opacity(titleFocused || titleHovered ? 1 : 0)
                        }
                        .onHover { titleHovered = $0 }
                        // Pull the field left so its text stays in line with everything below it.
                        .padding(.leading, -Self.titleInset)
                        .help("Click to rename. The folder is renamed too. Return saves, Esc cancels.")
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
                if running {
                    Button(role: .destructive) {
                        model.cancel(job)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop downloading. Finished files are kept.")
                } else if job.retryableCount > 0 {
                    Button {
                        model.retry(job)
                    } label: {
                        Label("Retry \(job.retryableCount)", systemImage: "arrow.clockwise")
                    }
                    .help("Download the failed and cancelled tracks again.")
                }
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
                        if let activity = track.activity, track.status.isActive {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text(activity + "…")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else if let note = track.note, !note.isEmpty {
                            Text(note).font(.caption).foregroundStyle(track.status == .failed ? .red : .secondary).lineLimit(1)
                        }
                    }
                }
                TableColumn("BPM") { track in
                    Text(track.bpm.map(String.init) ?? "").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(44)
                TableColumn("Key") { track in
                    if let key = track.key {
                        Text(key)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(CamelotColor.color(for: key).opacity(0.22), in: Capsule())
                            .help(track.keyName ?? key)
                    }
                }
                .width(48)
                TableColumn("Match") { track in
                    ConfidenceBadge(confidence: track.confidence, note: track.note)
                }
                .width(130)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
        .padding(20)
        // A text field keeps focus when you click bare window background, so end the edit here.
        .contentShape(Rectangle())
        .onTapGesture { titleFocused = false }
        .navigationTitle(job.name)
        .onAppear { title = job.name }
        .onChange(of: job.name) { _, new in if !titleFocused { title = new } }
    }

    private static let titleInset: CGFloat = 6

    /// Saves the typed title. An empty one is not a name, so the old one comes back.
    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != job.name { model.rename(job, to: trimmed) }
        // The store may have adjusted the name, or refused it.
        title = model.job(id: job.id)?.name ?? job.name
    }

    private var summary: String {
        var parts = ["\(done) of \(job.tracks.count) downloaded"]
        if failed > 0 { parts.append("\(failed) failed") }
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        if let dir = model.directory(of: job) { parts.append(dir.tildePath) }
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
        case .analyzing: Image(systemName: "waveform").foregroundStyle(.purple)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .cancelled: Image(systemName: "slash.circle").foregroundStyle(.secondary)
        }
    }
}

/// Camelot wheel hues: 1 is red-pink, going round to 12.
enum CamelotColor {
    static func color(for camelot: String) -> Color {
        let digits = camelot.prefix { $0.isNumber }
        guard let n = Int(digits), (1...12).contains(n) else { return .gray }
        return Color(hue: Double(n - 1) / 12, saturation: 0.75, brightness: 0.9)
    }
}
