import AppKit
import Foundation
import Observation
import SetlistCore

enum SidebarItem: Hashable {
    case text
    case link
    case youtubeSet
    case job(UUID)
}

/// Light, dark, or whatever macOS is set to.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// nil follows the system setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Where a YouTube Set identification currently is.
enum IdentifyStage: Equatable, Sendable {
    case fetchingInfo
    /// Fraction downloaded, nil until yt-dlp reports one.
    case downloadingAudio(Double?)
    case identifying(Double)

    var text: String {
        switch self {
        case .fetchingInfo: "Reading the video's description and comments"
        case let .downloadingAudio(fraction): fraction.map { "Downloading audio \(Int($0 * 100))%" } ?? "Downloading audio"
        case let .identifying(fraction): "Identifying songs \(Int(fraction * 100))%"
        }
    }

    /// nil shows an indeterminate bar.
    var fraction: Double? {
        switch self {
        case .fetchingInfo: nil
        case let .downloadingAudio(fraction): fraction
        case let .identifying(fraction): fraction
        }
    }
}

@MainActor
@Observable
final class AppModel {
    // MARK: Navigation and jobs
    var selection: SidebarItem? = .text
    var jobs: [Job] = []
    var isWorking = false
    var errorMessage: String?

    // MARK: Text draft
    var draftText = ""
    var draftName = ""
    var draftTracks: [Track] = []

    // MARK: Link draft
    var linkText = ""
    var linkName = ""
    var linkTracks: [Track] = []
    var linkFailures: [String] = []
    var isResolvingLinks = false

    // MARK: YouTube Set draft
    var setURL = ""
    var setName = ""
    var setTracks: [Track] = []
    /// Where the tracklist came from; nil until an identification finishes.
    var setSource: IdentifyResult.Source?
    /// Non-nil while an identification is running.
    var setStage: IdentifyStage?
    var setError: String?
    private var identifyTask: Task<Void, Never>?
    /// The link the current `setTracks` were identified from.
    private var setSourceURL: URL?
    /// Folder holding the downloaded `mix.wav` of the current draft, when Shazam was needed.
    private var setWorkDir: URL?

    // MARK: Settings (persisted in UserDefaults)
    var outputRoot: URL {
        didSet { defaults.set(outputRoot.path, forKey: Keys.outputRoot) }
    }
    var audioQuality: String {
        didSet { defaults.set(audioQuality, forKey: Keys.audioQuality) }
    }
    var keepOriginalMix: Bool {
        didSet { defaults.set(keepOriginalMix, forKey: Keys.keepOriginalMix) }
    }
    var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }
    var ytDlpVersion: String?
    var isUpdatingYtDlp = false

    private let defaults: UserDefaults
    let runner: any CommandRunning
    let locator: ToolLocator

    enum Keys {
        static let outputRoot = "outputRoot"
        static let audioQuality = "audioQuality"
        static let keepOriginalMix = "keepOriginalMix"
        static let appearance = "appearance"
    }

    /// yt-dlp is killed if it prints nothing for this long, so one dead connection cannot hang a job.
    static let idleTimeout: TimeInterval = 180

    /// Scratch space for mix audio while a set is being identified.
    static let workRoot: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Setlist/work", isDirectory: true)

    init(defaults: UserDefaults = .standard, runner: any CommandRunning = ProcessRunner(idleTimeout: AppModel.idleTimeout), locator: ToolLocator = .standard()) {
        self.defaults = defaults
        self.runner = runner
        self.locator = locator
        self.outputRoot = defaults.string(forKey: Keys.outputRoot).map { URL(fileURLWithPath: $0) } ?? JobStore.defaultRoot
        self.audioQuality = defaults.string(forKey: Keys.audioQuality) ?? "0"
        self.keepOriginalMix = defaults.bool(forKey: Keys.keepOriginalMix)
        self.appearance = defaults.string(forKey: Keys.appearance).flatMap(AppAppearance.init) ?? .system
        // Mix audio left behind by a crash or quit is hundreds of megabytes; nothing can resume it.
        try? FileManager.default.removeItem(at: Self.workRoot)
        reloadJobs()
    }

    func applyAppearance() {
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    var store: JobStore { JobStore(root: outputRoot) }

    var downloader: Downloader {
        var options = DownloadOptions()
        options.quality = audioQuality
        let ffmpeg = FFmpeg(runner: runner, locator: locator)
        return Downloader(runner: runner, locator: locator, options: options) { url in
            // CPU-heavy, so keep it off the cooperative pool's main lanes.
            let analysis = await Task.detached(priority: .utility) { try? AudioAnalyzer().analyze(file: url) }.value
            if let analysis { try? await ffmpeg.writeTags(file: url, bpm: analysis.bpm, key: analysis.id3Key) }
            return analysis
        }
    }

    /// Download tasks by job id, so a running job can be stopped.
    private var runningTasks: [UUID: Task<Void, Never>] = [:]

    private static let nameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()

    static func defaultName(_ prefix: String, _ date: Date = Date()) -> String {
        "\(prefix) " + nameDateFormatter.string(from: date)
    }

    func job(id: UUID) -> Job? {
        jobs.first { $0.id == id }
    }

    /// Runs `work`, handing every value it emits to `receive` on the main actor in the order emitted.
    /// A `Task` per value would not guarantee that order.
    private func streaming<Value: Sendable, Output: Sendable>(
        to receive: @escaping @MainActor (Value) -> Void,
        _ work: (@escaping @Sendable (Value) -> Void) async throws -> Output
    ) async rethrows -> Output {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self)
        let consumer = Task { @MainActor in
            for await value in stream { receive(value) }
        }
        defer { continuation.finish() }
        let output = try await work { continuation.yield($0) }
        continuation.finish()
        await consumer.value
        return output
    }

    // MARK: Text

    func parseDraft() {
        draftTracks = TrackParser.parse(draftText).enumerated().map { i, query in
            Track(index: i + 1, query: query)
        }
    }

    /// The non-empty rows of a draft, renumbered from 1.
    private func readyTracks(_ tracks: [Track]) -> [Track] {
        var kept = tracks.filter { !$0.query.trimmingCharacters(in: .whitespaces).isEmpty }
        for i in kept.indices { kept[i].index = i + 1 }
        return kept
    }

    private func jobName(_ typed: String, fallback prefix: String) -> String {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? Self.defaultName(prefix) : name
    }

    func startPasteListJob() {
        let tracks = readyTracks(draftTracks)
        guard !tracks.isEmpty else { return }
        guard run(Job(name: jobName(draftName, fallback: "Text"), kind: .pasteList, tracks: tracks)) != nil else { return }
        draftText = ""
        draftTracks = []
        draftName = ""
    }

    // MARK: Link

    /// Expands pasted links into tracks: playlists become their entries, Spotify becomes "Artist - Title".
    func resolveLinks() async {
        isResolvingLinks = true
        defer { isResolvingLinks = false }
        let resolver = LinkResolver(runner: runner, locator: locator)
        let (queries, failures) = await resolver.resolveAll(linkText)
        linkTracks = queries.enumerated().map { i, q in Track(index: i + 1, query: q) }
        linkFailures = failures.map { "\($0.line): \($0.error)" }
    }

    func startLinkJob() {
        let tracks = readyTracks(linkTracks)
        guard !tracks.isEmpty else { return }
        guard run(Job(name: jobName(linkName, fallback: "Links"), kind: .link, tracks: tracks)) != nil else { return }
        linkText = ""
        linkTracks = []
        linkFailures = []
        linkName = ""
    }

    // MARK: YouTube Set

    var isIdentifying: Bool { identifyTask != nil }

    /// Rows a download would fetch: "Not found" rows are skipped until the user types a title.
    var setDownloadableCount: Int {
        readyTracks(setTracks).filter { $0.confidence != .low }.count
    }

    /// Finds the tracklist of the mix at `setURL`: from its description or comments when one is posted
    /// there, otherwise by downloading the audio and running ShazamKit over it.
    func startIdentify() {
        guard identifyTask == nil else { return }
        let text = setURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TrackParser.isURL(text), let url = URL(string: text) else {
            setError = "Paste the link of a YouTube mix first."
            return
        }
        discardSetWork()
        setTracks = []
        setSource = nil
        setError = nil
        setStage = .fetchingInfo
        identifyTask = Task {
            do {
                try await identify(url)
            } catch {
                // A stopped run ends in a cancellation or a killed yt-dlp; neither is worth an error message.
                if !Task.isCancelled { setError = error.localizedDescription }
                discardSetWork()
            }
            setStage = nil
            identifyTask = nil
        }
    }

    private func identify(_ url: URL) async throws {
        let fetcher = MixFetcher(runner: runner, locator: locator)
        let info = try await fetcher.fetchInfo(url: url)
        try Task.checkCancellation()
        if setName.trimmingCharacters(in: .whitespaces).isEmpty { setName = info.title }
        setSourceURL = url

        if let found = SetIdentifier.tracksFromText(info) {
            setTracks = found.tracks
            setSource = found.source
            return
        }

        let workDir = Self.workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let wav = workDir.appendingPathComponent("mix.wav")
        setWorkDir = workDir
        setStage = .downloadingAudio(nil)
        let identified = try await streaming(to: { [weak self] (stage: IdentifyStage) in
            // Late progress must not bring the bar back after the run has ended.
            if self?.setStage != nil { self?.setStage = stage }
        }) { emit in
            try await fetcher.fetchAudio(url: url, to: wav) { line in
                if let fraction = Downloader.downloadFraction(in: line) { emit(.downloadingAudio(fraction)) }
            }
            try Task.checkCancellation()
            emit(.identifying(0))
            return try await SetIdentifier(matcher: ShazamMatcher()).identify(wav: wav) { emit(.identifying($0)) }
        }
        guard !identified.isEmpty else {
            setError = "No songs could be identified in this mix."
            discardSetWork()
            return
        }
        setTracks = SetIdentifier.toTracks(identified)
        setSource = .shazam
    }

    func cancelIdentify() {
        identifyTask?.cancel()
    }

    private func discardSetWork() {
        if let dir = setWorkDir { try? FileManager.default.removeItem(at: dir) }
        setWorkDir = nil
    }

    func startYouTubeSetJob() {
        let tracks = readyTracks(setTracks)
        guard setDownloadableCount > 0 else { return }
        let job = Job(name: jobName(setName, fallback: "Set"), kind: .youtubeSet, sourceURL: setSourceURL, tracks: tracks)
        guard let saved = run(job) else { return }
        if keepOriginalMix, let workDir = setWorkDir, let dir = directory(of: saved) {
            try? FileManager.default.moveItem(at: workDir.appendingPathComponent("mix.wav"),
                                              to: dir.appendingPathComponent("original mix.wav"))
        }
        discardSetWork()
        setURL = ""
        setName = ""
        setTracks = []
        setSource = nil
        setSourceURL = nil
    }

    // MARK: Running jobs

    /// Saves a new job and starts its downloads. Returns the saved job, or nil when its folder could not be created.
    @discardableResult
    func run(_ job: Job) -> Job? {
        var job = job
        do {
            _ = try store.directory(for: &job)
            try store.save(job)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        jobs.insert(job, at: 0)
        selection = .job(job.id)
        resume(job)
        return job
    }

    /// Stops a running job. Tracks not yet finished are marked cancelled; finished files stay.
    func cancel(_ job: Job) {
        runningTasks[job.id]?.cancel()
    }

    private func apply(_ track: Track, to jobID: UUID) {
        guard let j = jobs.firstIndex(where: { $0.id == jobID }),
              let t = jobs[j].tracks.firstIndex(where: { $0.id == track.id }) else { return }
        jobs[j].tracks[t] = track
    }

    private func replace(_ job: Job) {
        if let j = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[j] = job
        } else {
            jobs.insert(job, at: 0)
        }
    }

    /// Re-runs the failed and cancelled tracks of a job.
    func retry(_ job: Job) {
        guard !isRunning(job), job.retryableCount > 0,
              let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        let reset = job.resettingForRetry()
        jobs[i] = reset
        resume(reset)
    }

    /// Downloads the pending tracks of a job that already exists in `jobs` and on disk.
    private func resume(_ job: Job) {
        isWorking = true
        let downloader = downloader
        let store = store
        let jobID = job.id
        runningTasks[jobID] = Task {
            var finished = await streaming(to: { (track: Track) in self.apply(track, to: jobID) }) { emit in
                await downloader.downloadAll(job: job, store: store, onUpdate: emit)
            }
            // A rename made during the run only changed the name; move the folder now that nothing writes to it.
            if let current = self.job(id: jobID), current.name != finished.name {
                finished.name = current.name
            }
            try? store.syncDirectory(&finished)
            replace(finished)
            runningTasks[jobID] = nil
            isWorking = !runningTasks.isEmpty
        }
    }

    func isRunning(_ job: Job) -> Bool {
        runningTasks[job.id] != nil
    }

    // MARK: History and files

    func reloadJobs() {
        do {
            var loaded = try store.loadAll()
            for i in loaded.indices {
                if runningTasks[loaded[i].id] != nil {
                    // The copy in memory is newer than the file: it has live progress and any pending rename.
                    if let live = job(id: loaded[i].id) { loaded[i] = live }
                } else if loaded[i].hasActiveTracks {
                    // Still "in progress" on disk but nothing is running it: a quit or crash cut it off.
                    loaded[i] = loaded[i].markingInterrupted()
                    try? store.save(loaded[i])
                }
            }
            jobs = loaded
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Renames a job. While it is still downloading only the name changes; the folder follows when it finishes.
    func rename(_ job: Job, to newName: String) {
        guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        var updated = jobs[i]
        do {
            try store.rename(&updated, to: newName, moveFolder: !isRunning(updated))
            jobs[i] = updated
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Moves a finished job's folder, downloads included, to the Trash and drops it from history.
    func moveToTrash(_ job: Job) {
        guard !isRunning(job) else { return }
        do {
            if let dir = directory(of: job), FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
            }
            jobs.removeAll { $0.id == job.id }
            if selection == .job(job.id) { selection = .text }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func directory(of job: Job) -> URL? {
        job.directoryName.map { outputRoot.appendingPathComponent($0, isDirectory: true) }
    }

    func revealInFinder(_ job: Job) {
        guard let dir = directory(of: job) else { return }
        NSWorkspace.shared.open(dir)
    }

    /// Running jobs keep writing to the folder they started in, so the folder cannot change under them.
    var canChangeOutputFolder: Bool { !isWorking }

    func chooseOutputFolder() {
        guard canChangeOutputFolder else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputRoot
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            outputRoot = url
            reloadJobs()
        }
    }

    func loadYtDlpVersion() async {
        ytDlpVersion = await YtDlpUpdater().installedVersion(runner: runner, locator: locator) ?? "not found"
    }

    func updateYtDlp() async {
        isUpdatingYtDlp = true
        defer { isUpdatingYtDlp = false }
        do {
            _ = try await YtDlpUpdater().update()
            await loadYtDlpVersion()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension URL {
    /// The path with the home folder shortened to `~`, for display.
    var tildePath: String { (path as NSString).abbreviatingWithTildeInPath }
}
