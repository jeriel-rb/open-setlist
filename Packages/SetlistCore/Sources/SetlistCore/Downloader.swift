import Foundation

public struct DownloadOptions: Sendable {
    /// yt-dlp `--audio-quality`: "0" (best) … "9", or a bitrate like "192K".
    public var quality: String = "0"
    /// Tracks downloaded at the same time.
    public var concurrency: Int = 2
    /// How the downloaded files are named.
    public var fileNameFormat: FileNameFormat = .standard

    public init() {}
}

public enum DownloadError: Error, Equatable, Sendable {
    case allSourcesFailed(lastStderr: String)
    case tool(ToolError)
    case cancelled
}

/// Downloads tracks as MP3 with yt-dlp, trying YouTube first and SoundCloud second.
public struct Downloader: Sendable {
    public typealias Analyzer = @Sendable (URL) async -> TrackAnalysis?

    public let runner: CommandRunning
    public let locator: ToolLocator
    public let options: DownloadOptions
    /// Optional BPM/key analysis run on each finished file.
    public let analyzer: Analyzer?

    public init(runner: CommandRunning, locator: ToolLocator, options: DownloadOptions = .init(), analyzer: Analyzer? = nil) {
        self.runner = runner
        self.locator = locator
        self.options = options
        self.analyzer = analyzer
    }

    /// 0…1 from a yt-dlp `[download]  45.2% of …` progress line, nil for any other line.
    public static func downloadFraction(in line: String) -> Double? {
        guard line.hasPrefix("[download]"),
              let range = line.range(of: #"(\d+(?:\.\d+)?)%"#, options: .regularExpression),
              let percent = Double(line[range].dropLast()) else { return nil }
        return min(max(percent / 100, 0), 1)
    }

    /// A short, human-readable description of a yt-dlp output line, or nil for noise.
    public static func activity(for line: String) -> String? {
        if line.hasPrefix("[download]") {
            return downloadFraction(in: line).map { "Downloading \(Int($0 * 100))%" } ?? "Downloading"
        }
        if line.hasPrefix("[ExtractAudio]") { return "Converting to MP3" }
        if line.hasPrefix("[Metadata]") || line.hasPrefix("[EmbedThumbnail]") || line.hasPrefix("[ThumbnailsConvertor]") { return "Adding cover and tags" }
        if line.hasPrefix("[youtube:search]") { return "Searching YouTube" }
        if line.hasPrefix("[soundcloud:search]") { return "Searching SoundCloud" }
        if line.hasPrefix("[youtube]") || line.hasPrefix("[soundcloud]") || line.hasPrefix("[info]") { return "Fetching video info" }
        return nil
    }

    /// Direct URLs are used as-is; search text becomes a YouTube then a SoundCloud search.
    public static func targets(for query: String) -> [String] {
        if TrackParser.isURL(query) { return [query] }
        return ["ytsearch1:\(query)", "scsearch1:\(query)"]
    }

    public static func arguments(target: String, outputTemplate: String, quality: String, ffmpeg: URL) -> [String] {
        [
            "--no-playlist",
            "--extract-audio", "--audio-format", "mp3", "--audio-quality", quality,
            "--embed-thumbnail", "--embed-metadata",
            "--no-overwrites", "--newline", "--progress",
            "--socket-timeout", "30", "--retries", "3", "--fragment-retries", "3",
            "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
            "--print", "after_move:filepath",
            "-o", outputTemplate,
            target,
        ]
    }

    /// Downloads one track into `dir`. Returns the final MP3 path. `onActivity` receives progress text.
    public func download(track: Track, into dir: URL, onActivity: (@Sendable (String) -> Void)? = nil) async -> Result<URL, DownloadError> {
        let ytDlp: URL, ffmpeg: URL
        do {
            ytDlp = try locator.url(for: .ytDlp)
            ffmpeg = try locator.url(for: .ffmpeg)
        } catch let error as ToolError {
            return .failure(.tool(error))
        } catch {
            return .failure(.allSourcesFailed(lastStderr: error.localizedDescription))
        }

        let stem = options.fileNameFormat.stem(index: track.index, query: track.query)
        let template = dir.appendingPathComponent(stem + ".%(ext)s").path
        var lastStderr = ""
        for target in Self.targets(for: track.query) {
            if Task.isCancelled { return .failure(.cancelled) }
            let args = Self.arguments(target: target, outputTemplate: template, quality: options.quality, ffmpeg: ffmpeg)
            onActivity?(target.hasPrefix("scsearch") ? "Searching SoundCloud" : target.hasPrefix("ytsearch") ? "Searching YouTube" : "Fetching video info")
            do {
                let result = try await runner.run(ytDlp, arguments: args) { line in
                    if let text = Self.activity(for: line) { onActivity?(text) }
                }
                if Task.isCancelled { return .failure(.cancelled) }
                if result.exitCode == 0,
                   let path = result.stdout.split(separator: "\n").map(String.init)
                       .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    return .success(URL(fileURLWithPath: path))
                }
                lastStderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                lastStderr = error.localizedDescription
            }
        }
        return .failure(.allSourcesFailed(lastStderr: lastStderr))
    }

    /// Downloads every pending track of the job, `options.concurrency` at a time, persisting progress
    /// to the store. `onUpdate` fires on every status change.
    public func downloadAll(job: Job, store: JobStore, onUpdate: @Sendable @escaping (Track) -> Void) async -> Job {
        var job = job
        let dir: URL
        do {
            dir = try store.directory(for: &job)
        } catch {
            for i in job.tracks.indices {
                job.tracks[i].status = .failed
                job.tracks[i].note = error.localizedDescription
            }
            return job
        }

        for i in job.tracks.indices where job.tracks[i].confidence == .low && job.tracks[i].status == .pending {
            job.tracks[i].status = .skipped
            onUpdate(job.tracks[i])
        }
        try? store.save(job)
        try? store.writeTracklist(job)

        let pending = job.tracks.filter { $0.status == .pending }
        let state = JobState(job: job)

        await withTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            var running = 0
            func launch(_ track: Track) {
                group.addTask {
                    if Task.isCancelled {
                        state.set(track.id, status: .cancelled, path: nil, note: nil)
                        onUpdate(state.track(track.id))
                        return
                    }
                    state.set(track.id, status: .searching, path: nil, note: nil)
                    onUpdate(state.track(track.id))
                    let result = await download(track: track, into: dir) { text in
                        // Synchronous so progress text is applied and reported in arrival order.
                        if let updated = state.setActivity(track.id, text) { onUpdate(updated) }
                    }
                    switch result {
                    case let .success(url):
                        if let analyzer {
                            state.set(track.id, status: .analyzing, path: url.path, note: nil, activity: "Analysing BPM and key")
                            onUpdate(state.track(track.id))
                            let analysis = await analyzer(url)
                            state.setAnalysis(track.id, analysis)
                        }
                        state.set(track.id, status: .done, path: url.path, note: nil)
                    case .failure(.cancelled):
                        state.set(track.id, status: .cancelled, path: nil, note: nil)
                    case let .failure(error):
                        state.set(track.id, status: .failed, path: nil, note: Self.describe(error))
                    }
                    onUpdate(state.track(track.id))
                    try? store.save(state.job)
                }
            }
            while running < max(1, options.concurrency), let next = iterator.next() {
                launch(next); running += 1
            }
            while await group.next() != nil {
                if let next = iterator.next() { launch(next) }
            }
        }

        job = state.job
        for i in job.tracks.indices where job.tracks[i].status.isActive {
            job.tracks[i].status = .cancelled
            job.tracks[i].activity = nil
            onUpdate(job.tracks[i])
        }
        try? store.save(job)
        try? store.writeFailed(job)
        return job
    }

    static func describe(_ error: DownloadError) -> String {
        switch error {
        case let .allSourcesFailed(stderr): return stderr.isEmpty ? "not found" : stderr
        case let .tool(toolError): return toolError.localizedDescription
        case .cancelled: return "cancelled"
        }
    }
}

/// Serialises concurrent track updates. Lock-based rather than an actor so progress callbacks
/// from the process reader can apply synchronously, in order.
private final class JobState: @unchecked Sendable {
    private let lock = NSLock()
    private var _job: Job

    init(job: Job) { self._job = job }

    var job: Job { lock.withLock { _job } }

    func set(_ id: UUID, status: TrackStatus, path: String?, note: String?, activity: String? = nil) {
        lock.withLock {
            guard let i = _job.tracks.firstIndex(where: { $0.id == id }) else { return }
            _job.tracks[i].status = status
            _job.tracks[i].activity = activity
            if let path { _job.tracks[i].outputPath = path }
            if let note { _job.tracks[i].note = note }
        }
    }

    /// Returns the updated track, or nil when nothing changed or the track is no longer active.
    /// yt-dlp prints many progress lines per percent; only a change is worth a UI update.
    func setActivity(_ id: UUID, _ text: String) -> Track? {
        lock.withLock {
            guard let i = _job.tracks.firstIndex(where: { $0.id == id }), _job.tracks[i].status.isActive,
                  _job.tracks[i].activity != text else { return nil }
            _job.tracks[i].activity = text
            if text.hasPrefix("Downloading") || text.hasPrefix("Converting") || text.hasPrefix("Adding") {
                _job.tracks[i].status = .downloading
            }
            return _job.tracks[i]
        }
    }

    func setAnalysis(_ id: UUID, _ analysis: TrackAnalysis?) {
        lock.withLock {
            guard let i = _job.tracks.firstIndex(where: { $0.id == id }), let analysis else { return }
            _job.tracks[i].bpm = analysis.bpm
            _job.tracks[i].key = analysis.camelot
            _job.tracks[i].keyName = analysis.keyName
        }
    }

    func track(_ id: UUID) -> Track {
        lock.withLock { _job.tracks.first { $0.id == id }! }
    }
}
