import SwiftUI
import SetlistCore

struct JobProgressView: View {
    @Environment(AppModel.self) private var model
    @Environment(Player.self) private var player
    let job: Job
    @State private var selectedTracks = Set<Track.ID>()
    /// The song being renamed from the right-click menu, and the name being typed for it.
    @State private var renaming: Track?
    @State private var newTrackName = ""
    /// Command-F: what is typed in the search field, and whether the field has the cursor.
    @State private var searchText = ""
    @State private var searching = false
    /// Set by an arrow key, so the row it moves to is played when a song is already playing.
    @State private var movedByArrow = false
    @State private var renamingFiles = false
    /// Click a column header to sort by it; click again to reverse.
    @State private var sortOrder = [KeyPathComparator(\Track.index)]
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
                    HStack(spacing: 6) {
                        Text(summary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let dir = model.directory(of: job) {
                            Text("·").foregroundStyle(.secondary)
                            Button {
                                model.revealInFinder(job)
                            } label: {
                                Label("Show in Finder", systemImage: "folder")
                            }
                            .buttonStyle(.link)
                            .help(dir.tildePath)
                        }
                    }
                }
                Spacer()
                if running {
                    Button(role: .destructive) {
                        model.cancel(job)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop downloading. Finished files are kept.")
                } else if job.canResumeMix {
                    Button {
                        model.retry(job)
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .help("Continue identifying the mix from where it stopped.")
                } else if job.retryableCount > 0 {
                    Button {
                        model.retry(job)
                    } label: {
                        Label("Retry \(job.retryableCount)", systemImage: "arrow.clockwise")
                    }
                    .help("Download the failed and cancelled tracks again.")
                }
                if !running, job.kind != .youtubeSet {
                    Button {
                        model.addSongs(to: job)
                    } label: {
                        Label("Add Songs…", systemImage: "plus")
                    }
                    .help("Paste more links and download them into this folder.")
                }
                if !running, job.tracks.contains(where: { $0.status == .done }) {
                    Button {
                        renamingFiles = true
                    } label: {
                        Label("Rename Files…", systemImage: "character.cursor.ibeam")
                    }
                    .help("Change how the files in this folder are named.")
                }
            }

            if let mix = job.mix, mix.phase != .finished || mix.message != nil {
                MixStatusView(mix: mix, running: running)
            }

            // Only while something is happening; a finished job has nothing left to show progress for.
            if running {
                ProgressView(value: Double(finished), total: Double(max(job.tracks.count, 1)))
            }

            Table(shownTracks.sorted(using: sortOrder), selection: $selectedTracks, sortOrder: $sortOrder) {
                TableColumn("", value: \.statusRank) { track in
                    StatusIcon(status: track.status)
                }
                .width(22)
                TableColumn("#", value: \.index) { track in
                    Text(String(format: "%02d", track.index)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(32)
                TableColumn("Time", value: \.startOrLast) { track in
                    Text(track.start.map(JobStore.timestamp) ?? "").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(job.kind == .youtubeSet ? 64 : 0)
                TableColumn("Track", value: \.displayName) { track in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.displayName).lineLimit(1)
                        if let activity = track.activity, track.status.isActive {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text(activity + "…")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else if track.status == .done, model.file(of: track, in: job) == nil {
                            Text("The file is no longer in the folder (deleted, moved or renamed outside the app).")
                                .font(.caption).foregroundStyle(.orange).lineLimit(1)
                        } else if let note = track.note, !note.isEmpty {
                            Text(note).font(.caption).foregroundStyle(track.status == .failed ? .red : .secondary).lineLimit(1)
                        }
                    }
                }
                TableColumn("BPM", value: \.bpmOrLast) { track in
                    Text(track.bpm.map(String.init) ?? "").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(44)
                TableColumn("Key", value: \.camelotRank) { track in
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
                TableColumn("Match", value: \.confidence.rawValue) { track in
                    ConfidenceBadge(confidence: track.confidence, note: track.note)
                }
                .width(130)
                TableColumn("Source", value: \.sourceLabel) { track in
                    if let address = track.knownSource, let url = URL(string: address) {
                        Link(track.sourceLabel, destination: url)
                            .help("Open \(address)")
                    }
                }
                .width(84)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            // Double-click (the primary action) previews a downloaded song in the mini player.
            .contextMenu(forSelectionType: Track.ID.self) { ids in
                let chosen = job.tracks.filter { ids.contains($0.id) }
                let files = chosen.compactMap { model.file(of: $0, in: job) }
                if chosen.count == 1, let track = chosen.first {
                    if !files.isEmpty { Button("Play") { play(track) } }
                    Button("Rename…") {
                        newTrackName = track.displayName
                        renaming = track
                    }
                    .disabled(!model.canEditTracks(of: job))
                }
                if !files.isEmpty {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files) }
                }
                if !chosen.isEmpty {
                    Divider()
                    Button(chosen.count == 1 ? "Delete" : "Delete \(chosen.count) Songs", role: .destructive) {
                        model.delete(chosen, from: job)
                        selectedTracks.subtract(ids)
                    }
                    .disabled(!model.canEditTracks(of: job))
                }
            } primaryAction: { ids in
                if let track = job.tracks.first(where: { ids.contains($0.id) }) { play(track) }
            }
            // Space plays the selected song, or pauses and resumes it when it is the one playing.
            .onKeyPress(.space) {
                guard let track = selectedTrack else { return .ignored }
                if let file = model.file(of: track, in: job), file == player.fileURL {
                    player.toggle()
                } else {
                    play(track)
                }
                return .handled
            }
            // The arrows move the selection as usual; while a song plays, the row they land on plays next.
            .onKeyPress(keys: [.upArrow, .downArrow]) { _ in
                movedByArrow = true
                // At the top or bottom row nothing moves; forget the key so a later click does not play.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { movedByArrow = false }
                return .ignored
            }
            // Left and right jump through the playing song by 8 bars, one phrase, so each press lands on the
            // next section (intro, build-up, drop). With Shift it is 1 bar, for lining up exactly.
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                guard let playing = player.fileURL else { return .ignored }
                let track = job.tracks.first { model.file(of: $0, in: job) == playing } ?? selectedTrack
                let length = (track ?? Track(index: 0, query: "")).seconds(forBars: press.modifiers.contains(.shift) ? 1 : 8)
                let target = player.currentTime + (press.key == .rightArrow ? length : -length)
                player.seek(to: min(target, max(0, player.duration - 1)))
                return .handled
            }
            .onChange(of: selectedTracks) { _, _ in
                guard movedByArrow else { return }
                movedByArrow = false
                if player.isPlaying, let track = selectedTrack, model.file(of: track, in: job) != nil { play(track) }
            }
        }
        .padding(20)
        // A text field keeps focus when you click bare window background, so end the edit here.
        .contentShape(Rectangle())
        .onTapGesture { titleFocused = false }
        .navigationTitle(job.name)
        .searchable(text: $searchText, isPresented: $searching, prompt: "Find a song")
        // A song the search hides is no longer selected, so Space and Delete only act on what is on screen.
        .onChange(of: searchText) { _, _ in selectedTracks.formIntersection(shownTracks.map(\.id)) }
        // Command-F puts the cursor in the search field, as in other Mac apps.
        .background {
            Button("Find") { searching = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .sheet(isPresented: $renamingFiles) {
            RenameFilesSheet(job: job)
        }
        .alert("Rename Song", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { track in
            TextField("Artist - Title", text: $newTrackName)
            Button("Rename") { model.rename(track, in: job, to: newTrackName) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Write it as Artist - Title. The file is renamed to match.")
        }
        .onAppear { title = job.name }
        .onChange(of: job.name) { _, new in if !titleFocused { title = new } }
    }

    private static let titleInset: CGFloat = 6

    /// The songs that match what is typed in the search field: every word must be in the song's name,
    /// its BPM, key or source, in any order, ignoring capitals and accents. All songs when it is empty.
    private var shownTracks: [Track] {
        let words = searchText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return job.tracks }
        return job.tracks.filter { track in
            let text = [track.displayName, track.bpm.map(String.init) ?? "", track.key ?? "", track.sourceLabel].joined(separator: " ")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// The one selected song, when exactly one is selected.
    private var selectedTrack: Track? {
        guard selectedTracks.count == 1, let id = selectedTracks.first else { return nil }
        return job.tracks.first { $0.id == id }
    }

    private func play(_ track: Track) {
        guard let file = model.file(of: track, in: job) else {
            if track.status == .done { model.errorMessage = "The file for “\(track.displayName)” is no longer in the job folder." }
            return
        }
        do {
            try player.play(file, title: file.deletingPathExtension().lastPathComponent)
        } catch {
            model.errorMessage = "Could not play “\(track.displayName)”: \(error.localizedDescription)"
        }
    }

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
        return parts.joined(separator: " · ")
    }
}

/// Pick a new name format for the files one job has already downloaded.
struct RenameFilesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let job: Job
    @State private var format = FileNameFormat.standard

    private var fileCount: Int { job.tracks.filter { $0.status == .done }.count }
    private var current: FileNameFormat { job.fileNameFormat ?? .standard }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                FileNameSettings(format: $format, title: "Rename the files in “\(job.name)”",
                                 note: "Only this folder changes; other jobs and new downloads keep the format from Settings.")
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(fileCount == 1 ? "Rename 1 File" : "Rename \(fileCount) Files") {
                    model.renameFiles(of: job, to: format)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(format == current)
            }
            .padding(16)
        }
        .frame(width: 500)
        .onAppear { format = current }
    }
}

/// What is happening to the mix itself: its audio download, how far Shazam has listened, and why it stopped.
struct MixStatusView: View {
    let mix: MixState
    let running: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: mix.phase == .downloadingAudio ? "arrow.down.circle" : "waveform")
                    .foregroundStyle(.secondary)
                Text(headline)
                Spacer()
                Text(detail)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if mix.phase != .finished {
                if let progress, progress > 0 || !running {
                    ProgressView(value: progress)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            if let message = mix.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var progress: Double? {
        switch mix.phase {
        case .downloadingAudio: mix.audioProgress
        case .identifying: mix.identifyProgress
        case .finished: 1
        }
    }

    private var headline: String {
        switch mix.phase {
        case .downloadingAudio:
            running ? "Downloading the mix audio" : "Mix audio not downloaded yet"
        case .identifying:
            running ? "Listening to \(MixState.fileName) with Shazam" : "Paused. \(MixState.fileName) is saved in the job folder"
        case .finished:
            "Finished listening to the mix"
        }
    }

    private var detail: String {
        switch mix.phase {
        case .downloadingAudio:
            return mix.audioProgress.map { "\(Int($0 * 100))%" } ?? ""
        case .identifying, .finished:
            guard let duration = mix.duration, let progress = mix.identifyProgress else { return "" }
            return "\(JobStore.timestamp(duration * progress)) of \(JobStore.timestamp(duration))"
        }
    }
}

/// Values the table sorts by. Tracks that have no value yet sort after those that do.
extension Track {
    var statusRank: String { status.rawValue }
    /// The site a song was downloaded from, by name. Empty when it is not known.
    var sourceLabel: String {
        guard let knownSource, let host = URL(string: knownSource)?.host?.lowercased() else { return "" }
        if host.hasSuffix("youtube.com") || host.hasSuffix("youtu.be") { return "YouTube" }
        if host.hasSuffix("soundcloud.com") { return "SoundCloud" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    var startOrLast: Double { start ?? .greatestFiniteMagnitude }
    var bpmOrLast: Int { bpm ?? .max }
    /// Camelot codes in wheel order: 1A, 1B, 2A … 12B.
    var camelotRank: Int {
        guard let key, let number = Int(key.prefix { $0.isNumber }) else { return .max }
        return number * 2 + (key.hasSuffix("B") ? 1 : 0)
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
