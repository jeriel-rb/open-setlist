import Foundation

public struct DownloadOptions: Sendable {
    /// yt-dlp `--audio-quality`: "0" (best) … "9", or a bitrate like "192K".
    public var quality: String = "0"
    /// Tracks downloaded at the same time.
    public var concurrency: Int = 2

    public init() {}
}

public enum DownloadError: Error, Equatable, Sendable {
    case allSourcesFailed(lastStderr: String)
    case tool(ToolError)
}

/// Downloads tracks as MP3 with yt-dlp, trying YouTube first and SoundCloud second.
public struct Downloader: Sendable {
    public let runner: CommandRunning
    public let locator: ToolLocator
    public let options: DownloadOptions

    public init(runner: CommandRunning, locator: ToolLocator, options: DownloadOptions = .init()) {
        self.runner = runner
        self.locator = locator
        self.options = options
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
            "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
            "--print", "after_move:filepath",
            "-o", outputTemplate,
            target,
        ]
    }

    /// Downloads one track into `dir`. Returns the final MP3 path.
    public func download(track: Track, into dir: URL) async -> Result<URL, DownloadError> {
        let ytDlp: URL, ffmpeg: URL
        do {
            ytDlp = try locator.url(for: .ytDlp)
            ffmpeg = try locator.url(for: .ffmpeg)
        } catch let error as ToolError {
            return .failure(.tool(error))
        } catch {
            return .failure(.allSourcesFailed(lastStderr: error.localizedDescription))
        }

        let template = dir.appendingPathComponent(track.fileStem + ".%(ext)s").path
        var lastStderr = ""
        for target in Self.targets(for: track.query) {
            let args = Self.arguments(target: target, outputTemplate: template, quality: options.quality, ffmpeg: ffmpeg)
            do {
                let result = try await runner.run(ytDlp, arguments: args, onLine: nil)
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
                    await state.set(track.id, status: .searching, path: nil, note: nil)
                    onUpdate(await state.track(track.id))
                    let result = await download(track: track, into: dir)
                    switch result {
                    case let .success(url):
                        await state.set(track.id, status: .done, path: url.path, note: nil)
                    case let .failure(error):
                        await state.set(track.id, status: .failed, path: nil, note: Self.describe(error))
                    }
                    onUpdate(await state.track(track.id))
                    try? store.save(await state.job)
                }
            }
            while running < max(1, options.concurrency), let next = iterator.next() {
                launch(next); running += 1
            }
            while await group.next() != nil {
                if let next = iterator.next() { launch(next) }
            }
        }

        job = await state.job
        try? store.save(job)
        try? store.writeFailed(job)
        return job
    }

    private static func describe(_ error: DownloadError) -> String {
        switch error {
        case let .allSourcesFailed(stderr): return stderr.isEmpty ? "not found" : stderr
        case let .tool(toolError): return toolError.localizedDescription
        }
    }
}

/// Serialises concurrent track updates.
private actor JobState {
    var job: Job

    init(job: Job) { self.job = job }

    func set(_ id: UUID, status: TrackStatus, path: String?, note: String?) {
        guard let i = job.tracks.firstIndex(where: { $0.id == id }) else { return }
        job.tracks[i].status = status
        if let path { job.tracks[i].outputPath = path }
        if let note { job.tracks[i].note = note }
    }

    func track(_ id: UUID) -> Track {
        job.tracks.first { $0.id == id }!
    }
}
