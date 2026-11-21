import Foundation

public struct DownloadOptions: Sendable {
    /// yt-dlp `--audio-quality`: "0" (best) … "9", or a bitrate like "192K".
    public var quality: String = "0"
    /// Tracks downloaded at the same time.
    public var concurrency: Int = 2
    /// How the downloaded files are named.
    public var fileNameFormat: FileNameFormat = .standard
    /// How long to wait before trying again after a site refuses for a moment. Longer on the second wait.
    public var retryPause: Duration = .seconds(3)

    public init() {}

    /// How many downloads suit a Mac with `cores` processor cores: half of them, since each download also
    /// converts to MP3, at least 2, and never more than 6 so a site is not hit hard enough to refuse.
    public static func recommendedConcurrency(cores: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        min(6, max(2, cores / 2))
    }
}

public enum DownloadError: Error, Equatable, Sendable {
    case allSourcesFailed(lastStderr: String)
    case tool(ToolError)
    case cancelled
}

/// Downloads tracks as MP3 with yt-dlp. A song name is searched for on YouTube and SoundCloud and the
/// result that best matches the name, version included, is the one downloaded.
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
        if line.hasPrefix("[youtube]") || line.hasPrefix("[soundcloud]") || line.hasPrefix("[info]") { return "Getting the song's details" }
        return nil
    }

    /// How many results each site is asked for when looking for the best match.
    public static let searchDepth = 5
    /// How many of the best matches are tried before giving up on a song.
    public static let matchAttempts = 3

    public static func searchArguments(site: String, query: String) -> [String] {
        ["--flat-playlist", "--dump-json", "--no-warnings", "--socket-timeout", "30", "\(site)\(searchDepth):\(query)"]
    }

    /// The pages worth downloading for a song name, best match first: results from YouTube and
    /// SoundCloud, searched at the same time. Empty when neither search returned anything.
    func bestMatches(for query: String, ytDlp: URL) async -> [String] {
        async let youTube = try? runner.run(ytDlp, arguments: Self.searchArguments(site: "ytsearch", query: query), onLine: nil)
        async let soundCloud = try? runner.run(ytDlp, arguments: Self.searchArguments(site: "scsearch", query: query), onLine: nil)
        // YouTube first: on an equal match it stays ahead, as it always was.
        let found = [await youTube, await soundCloud].flatMap { CandidateRanker.parse(searchOutput: $0?.stdout ?? "") }
        return CandidateRanker.ranked(found, for: query).prefix(Self.matchAttempts).map(\.url)
    }

    /// Direct URLs are used as-is; search text becomes a YouTube then a SoundCloud search. For search
    /// text this is the fallback, used when `bestMatches` finds nothing to choose from.
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
            "--print", "after_move:webpage_url", "--print", "after_move:filepath",
            "-o", outputTemplate,
            target,
        ]
    }

    /// A finished download: the MP3 and the page its audio came from.
    public struct Downloaded: Equatable, Sendable {
        public let file: URL
        public let source: String?
        /// The song's name read from a link's page for this download, when it was not known before.
        public var name: String? = nil
    }

    /// How many times one page is tried when the site refuses for a moment.
    public static let attemptsPerTarget = 3

    /// True for a failure that often goes away by itself: the site refusing or limiting for a moment,
    /// a server error, a dropped connection.
    public static func isTransient(_ stderr: String) -> Bool {
        stderr.range(of: #"HTTP Error (403|429|5\d\d)|Too Many Requests|Connection reset|Remote end closed|IncompleteRead"#,
                     options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Downloads one track into `dir`. Returns the final MP3 path. `onActivity` receives progress text.
    public func download(track: Track, into dir: URL, onActivity: (@Sendable (String) -> Void)? = nil) async -> Result<URL, DownloadError> {
        await fetch(track: track, into: dir, onActivity: onActivity).map(\.file)
    }

    /// Like `download`, also reporting where the audio was found.
    public func fetch(track: Track, into dir: URL, onActivity: (@Sendable (String) -> Void)? = nil) async -> Result<Downloaded, DownloadError> {
        let ytDlp: URL, ffmpeg: URL
        do {
            ytDlp = try locator.url(for: .ytDlp)
            ffmpeg = try locator.url(for: .ffmpeg)
        } catch let error as ToolError {
            return .failure(.tool(error))
        } catch {
            return .failure(.allSourcesFailed(lastStderr: error.localizedDescription))
        }

        // A link without a name yet (pasted on its own, or downloaded before its playlist was read to the
        // end): read the name from its page first, so the file is named like every other song.
        var track = track
        var readName: String?
        if TrackParser.isURL(track.query), (track.songName ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
           LinkResolver.needsNameLookup(track.query) {
            onActivity?("Reading the song's name")
            readName = await LinkResolver(runner: runner, locator: locator).songName(at: track.query)
            track.songName = readName
        }
        if Task.isCancelled { return .failure(.cancelled) }

        let stem = options.fileNameFormat.stem(for: track)
        let template = dir.appendingPathComponent(stem + ".%(ext)s").path
        var lastStderr = ""
        var targets = Self.targets(for: track.query)
        if !TrackParser.isURL(track.query) {
            onActivity?("Searching YouTube and SoundCloud")
            let matches = await bestMatches(for: track.query, ytDlp: ytDlp)
            if !matches.isEmpty { targets = matches }
        }
        for target in targets {
            let args = Self.arguments(target: target, outputTemplate: template, quality: options.quality, ffmpeg: ffmpeg)
            for attempt in 1...Self.attemptsPerTarget {
                if Task.isCancelled { return .failure(.cancelled) }
                onActivity?(attempt > 1 ? "Trying again" : target.hasPrefix("scsearch") ? "Searching SoundCloud" : target.hasPrefix("ytsearch") ? "Searching YouTube" : "Getting the song's details")
                do {
                    let result = try await runner.run(ytDlp, arguments: args) { line in
                        if let text = Self.activity(for: line) { onActivity?(text) }
                    }
                    if Task.isCancelled { return .failure(.cancelled) }
                    // yt-dlp prints the page address, then the file path, once the file is in place.
                    let printed = result.stdout.split(separator: "\n").map(String.init)
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    if result.exitCode == 0, let path = printed.last {
                        let source = printed.dropLast().last(where: TrackParser.isURL)
                        return .success(Downloaded(file: URL(fileURLWithPath: path), source: source, name: readName))
                    }
                    lastStderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    lastStderr = error.localizedDescription
                }
                removeLeftovers(of: track, in: dir)
                // A refusal that lasts a moment is worth another try at the same page; anything else is not.
                guard attempt < Self.attemptsPerTarget, Self.isTransient(lastStderr) else { break }
                onActivity?("The site refused, waiting to try again")
                try? await Task.sleep(for: options.retryPause * attempt)
            }
        }
        return .failure(.allSourcesFailed(lastStderr: lastStderr))
    }

    /// A failed attempt can leave a cover image or a partial download behind, which the next attempt
    /// (another page, with other file types) would never tidy up. Only for songs found by name: a
    /// link's file is named after the video, which is not known here.
    private func removeLeftovers(of track: Track, in dir: URL) {
        guard !TrackParser.isURL(track.query), !Task.isCancelled else { return }
        let prefix = options.fileNameFormat.fileName(index: track.index, text: track.query)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasPrefix(prefix + ".") && !name.hasSuffix(".mp3") {
            // Just extensions after the name (".webp", ".f251.webm.part"), so "Song. Part 2" is another song.
            let rest = name.dropFirst(prefix.count)
            guard rest.range(of: #"^(\.[A-Za-z0-9]{1,8}){1,3}$"#, options: .regularExpression) != nil else { continue }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
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
                    let result = await fetch(track: track, into: dir) { text in
                        // Synchronous so progress text is applied and reported in arrival order.
                        if let updated = state.setActivity(track.id, text) { onUpdate(updated) }
                    }
                    switch result {
                    case let .success(downloaded):
                        let url = downloaded.file
                        state.setSource(track.id, downloaded.source)
                        state.setName(track.id, downloaded.name)
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
        // Again: a link's name may only have been read while it was downloaded.
        try? store.writeTracklist(job)
        try? store.writeFailed(job)
        return job
    }

    static func describe(_ error: DownloadError) -> String {
        switch error {
        case let .allSourcesFailed(stderr): return DownloadFailure.describe(stderr)
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

    func setSource(_ id: UUID, _ source: String?) {
        lock.withLock {
            guard let i = _job.tracks.firstIndex(where: { $0.id == id }), let source else { return }
            _job.tracks[i].sourceURL = source
        }
    }

    func setName(_ id: UUID, _ name: String?) {
        lock.withLock {
            guard let i = _job.tracks.firstIndex(where: { $0.id == id }), let name else { return }
            _job.tracks[i].songName = name
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
