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
    var draftName = AppModel.defaultName("Text")
    var draftTracks: [Track] = []

    // MARK: Link draft
    var linkText = ""
    var linkName = AppModel.defaultName("Links")
    var linkTracks: [Track] = []
    var linkFailures: [String] = []
    var isResolvingLinks = false

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
    var ytDlpVersion: String?

    private let defaults: UserDefaults
    let runner: any CommandRunning
    let locator: ToolLocator

    enum Keys {
        static let outputRoot = "outputRoot"
        static let audioQuality = "audioQuality"
        static let keepOriginalMix = "keepOriginalMix"
    }

    init(defaults: UserDefaults = .standard, runner: any CommandRunning = ProcessRunner(), locator: ToolLocator = .standard()) {
        self.defaults = defaults
        self.runner = runner
        self.locator = locator
        self.outputRoot = defaults.string(forKey: Keys.outputRoot).map { URL(fileURLWithPath: $0) } ?? JobStore.defaultRoot
        self.audioQuality = defaults.string(forKey: Keys.audioQuality) ?? "0"
        self.keepOriginalMix = defaults.bool(forKey: Keys.keepOriginalMix)
        reloadJobs()
    }

    var store: JobStore { JobStore(root: outputRoot) }

    var downloader: Downloader {
        var options = DownloadOptions()
        options.quality = audioQuality
        return Downloader(runner: runner, locator: locator, options: options)
    }

    static func defaultName(_ prefix: String, _ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return "\(prefix) " + f.string(from: date)
    }

    func job(id: UUID) -> Job? {
        jobs.first { $0.id == id }
    }

    // MARK: Paste List

    func parseDraft() {
        draftTracks = TrackParser.parse(draftText).enumerated().map { i, query in
            Track(index: i + 1, query: query)
        }
    }

    func renumber(_ tracks: inout [Track]) {
        for i in tracks.indices { tracks[i].index = i + 1 }
    }

    func startPasteListJob() {
        var tracks = draftTracks.filter { !$0.query.trimmingCharacters(in: .whitespaces).isEmpty }
        renumber(&tracks)
        guard !tracks.isEmpty else { return }
        let job = Job(name: draftName.isEmpty ? Self.defaultName("Text") : draftName, kind: .pasteList, tracks: tracks)
        draftText = ""
        draftTracks = []
        draftName = Self.defaultName("Text")
        run(job)
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
        var tracks = linkTracks.filter { !$0.query.trimmingCharacters(in: .whitespaces).isEmpty }
        renumber(&tracks)
        guard !tracks.isEmpty else { return }
        let job = Job(name: linkName.isEmpty ? Self.defaultName("Links") : linkName, kind: .link, tracks: tracks)
        linkText = ""
        linkTracks = []
        linkFailures = []
        linkName = Self.defaultName("Links")
        run(job)
    }

    /// Runs a job's downloads, keeping `jobs` live-updated.
    func run(_ job: Job) {
        var job = job
        do {
            _ = try store.directory(for: &job)
            try store.save(job)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        jobs.insert(job, at: 0)
        selection = .job(job.id)
        isWorking = true
        let downloader = downloader
        let store = store
        let snapshot = job
        let jobID = job.id
        Task {
            let finished = await downloader.downloadAll(job: snapshot, store: store) { track in
                Task { @MainActor [weak self] in self?.apply(track, to: jobID) }
            }
            replace(finished)
            isWorking = false
        }
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

    // MARK: History and files

    func reloadJobs() {
        do {
            jobs = try store.loadAll()
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

    func chooseOutputFolder() {
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
        guard let ytDlp = try? locator.url(for: .ytDlp) else {
            ytDlpVersion = "not found"
            return
        }
        let result = try? await runner.run(ytDlp, arguments: ["--version"], onLine: nil)
        ytDlpVersion = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }
}
