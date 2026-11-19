import Foundation

/// Identifies a mix by listening to it and downloads its songs as they are found.
///
/// The mix audio is saved in the job folder, then sent to the matcher one slice at a time. After every
/// slice the result is written to `job.json` and the tracklist is rebuilt, so the list grows while you
/// watch and a run that is stopped, fails or loses its connection picks up at the next slice. A song is
/// downloaded as soon as later slices have settled what it is.
public struct SetRunner: Sendable {
    public typealias Preflight = @Sendable () async throws -> Void

    public enum Error: Swift.Error, LocalizedError {
        case missingSource
        /// The matcher is not answering at all: wrong signing, service not enabled, or offline.
        case matcherUnavailable(underlying: Swift.Error)
        /// The matcher failed `attempts` times in a row on the slice starting at `position` seconds.
        case matcherKeptFailing(position: Double, attempts: Int, underlying: Swift.Error)

        public var errorDescription: String? {
            switch self {
            case .missingSource:
                "This job has no mix link to identify."
            case let .matcherUnavailable(underlying):
                "Shazam is not available to this copy of Setlist: \(underlying.localizedDescription) " +
                "The app must be signed with an Apple Developer team whose App ID has the ShazamKit service enabled, and you must be online. Nothing was downloaded."
            case let .matcherKeptFailing(position, attempts, underlying):
                "Stopped at \(JobStore.timestamp(position)): Shazam failed \(attempts) times in a row (\(underlying.localizedDescription)). " +
                "What was identified so far is saved; Resume continues from here."
            }
        }
    }

    public let fetcher: MixFetcher
    public let matcher: SliceMatching
    public let downloader: Downloader
    public let store: JobStore

    public var sliceSeconds: Double = 30
    public var windowOffset: Double = 9
    public var windowSeconds: Double = 12
    /// Pause between slices, to stay polite to Shazam.
    public var delay: Duration = .milliseconds(1500)
    /// A slice is tried this many times before the run stops.
    public var maxAttempts = 3
    public var retryDelay: Duration = .seconds(3)
    /// Keep the mix audio as `original mix.wav` once everything is identified.
    public var keepMix = false
    /// Run before anything is downloaded; a throw aborts the run.
    public var preflight: Preflight?

    /// While identification is still running, the last tracks of the list can still change
    /// (a one-slice blip is absorbed into its neighbours), so they are not downloaded yet.
    static let unsettledTail = 2

    public init(fetcher: MixFetcher, matcher: SliceMatching, downloader: Downloader, store: JobStore) {
        self.fetcher = fetcher
        self.matcher = matcher
        self.downloader = downloader
        self.store = store
    }

    /// Runs or resumes the job. `onUpdate` receives the whole job on every change. Returns its final state.
    public func run(job: Job, onUpdate: @escaping @Sendable (Job) -> Void) async -> Job {
        var job = job.resettingForRetry()
        if job.mix == nil { job.mix = MixState() }
        job.mix?.message = nil
        let state = Locked(job)
        let publish: @Sendable () -> Void = { onUpdate(state.value) }
        let checkpoint: @Sendable () -> Void = {
            let snapshot = state.value
            try? store.save(snapshot)
            onUpdate(snapshot)
        }

        do {
            guard let source = job.sourceURL else { throw Error.missingSource }
            let dir = try state.mutate { try store.directory(for: &$0) }
            checkpoint()
            if let preflight {
                do { try await preflight() } catch is CancellationError { throw CancellationError() } catch {
                    throw Error.matcherUnavailable(underlying: error)
                }
            }

            let wav = dir.appendingPathComponent(MixState.fileName)
            let needsAudio = state.value.mix?.phase == .downloadingAudio || !FileManager.default.fileExists(atPath: wav.path)
            if needsAudio, state.value.mix?.phase != .finished {
                state.mutate { $0.mix?.phase = .downloadingAudio }
                checkpoint()
                try await fetcher.fetchAudio(url: source, to: wav) { line in
                    guard let fraction = Downloader.downloadFraction(in: line) else { return }
                    let changed = state.mutate { job -> Bool in
                        // Whole percents only: yt-dlp reports far more often than the UI needs.
                        let rounded = (fraction * 100).rounded() / 100
                        guard job.mix?.audioProgress != rounded else { return false }
                        job.mix?.audioProgress = rounded
                        return true
                    }
                    if changed { publish() }
                }
                try Task.checkCancellation()
                state.mutate {
                    $0.mix?.phase = .identifying
                    $0.mix?.audioProgress = nil
                }
                checkpoint()
            }

            try await identifyAndDownload(wav: wav, dir: dir, state: state, publish: publish, checkpoint: checkpoint)

            if state.value.mix?.phase == .finished {
                if keepMix {
                    try? FileManager.default.moveItem(at: wav, to: dir.appendingPathComponent(MixState.keptFileName))
                } else {
                    try? FileManager.default.removeItem(at: wav)
                }
                if state.value.tracks.isEmpty {
                    state.mutate { $0.mix?.message = "No songs could be identified in this mix." }
                }
            }
        } catch {
            // A stopped run ends in a cancellation or a killed yt-dlp; neither needs explaining.
            if !Task.isCancelled {
                state.mutate { $0.mix?.message = error.localizedDescription }
            }
        }

        state.mutate { job in
            // Anything not downloaded by now waits for a Resume or Retry.
            for i in job.tracks.indices where job.tracks[i].status.isActive {
                job.tracks[i].status = .cancelled
                job.tracks[i].activity = nil
            }
        }
        let finished = state.value
        try? store.save(finished)
        try? store.writeTracklist(finished)
        try? store.writeFailed(finished)
        onUpdate(finished)
        return finished
    }

    private func identifyAndDownload(wav: URL, dir: URL, state: Locked<Job>,
                                     publish: @escaping @Sendable () -> Void,
                                     checkpoint: @escaping @Sendable () -> Void) async throws {
        let (queue, feed) = AsyncStream.makeStream(of: Track.self)
        let queued = Locked(Set<UUID>())
        /// Hands every settled, not yet downloaded track to the download worker, once.
        let enqueueSettled: @Sendable () -> Void = {
            let job = state.value
            let finished = job.mix?.phase == .finished
            let settled = finished ? job.tracks : Array(job.tracks.dropLast(Self.unsettledTail))
            for track in settled where track.status == .pending && track.confidence != .low {
                if queued.mutate({ $0.insert(track.id).inserted }) { feed.yield(track) }
            }
        }

        var failure: Swift.Error?
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await downloadSettled(queue, into: dir, state: state, publish: publish, checkpoint: checkpoint) }
            do {
                if state.value.mix?.phase == .identifying {
                    try await identify(wav: wav, state: state, checkpoint: checkpoint, enqueueSettled: enqueueSettled)
                }
                enqueueSettled()
            } catch {
                failure = error
            }
            feed.finish()
            await group.waitForAll()
        }
        if let failure { throw failure }
    }

    private func identify(wav: URL, state: Locked<Job>, checkpoint: @Sendable () -> Void, enqueueSettled: @Sendable () -> Void) async throws {
        let reader = try AudioWindowReader(fileURL: wav)
        var starts: [Double] = []
        var start = 0.0
        while start + windowOffset + windowSeconds <= reader.duration {
            starts.append(start)
            start += sliceSeconds
        }
        state.mutate {
            $0.mix?.duration = reader.duration
            $0.mix?.sliceCount = starts.count
        }
        checkpoint()
        enqueueSettled()

        let done = state.value.mix?.slices.count ?? 0
        for i in min(done, starts.count)..<starts.count {
            try Task.checkCancellation()
            let buffer = try reader.buffer(start: starts[i] + windowOffset, length: windowSeconds)
            var hit: Hit?
            var attempt = 0
            while true {
                do {
                    hit = try await matcher.match(buffer)
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    attempt += 1
                    if attempt >= maxAttempts {
                        throw Error.matcherKeptFailing(position: starts[i], attempts: attempt, underlying: error)
                    }
                    try await Task.sleep(for: retryDelay)
                }
            }
            state.mutate { job in
                job.mix?.slices.append(SliceMatch(start: starts[i], hit: hit))
                Self.rebuildTracks(&job, totalDuration: reader.duration)
            }
            checkpoint()
            enqueueSettled()
            if i + 1 < starts.count, delay > .zero {
                try await Task.sleep(for: delay)
            }
        }
        state.mutate { $0.mix?.phase = .finished }
        checkpoint()
    }

    /// Rebuilds the tracklist from the slices heard so far, keeping the status, file and analysis of
    /// every track that is still in it.
    static func rebuildTracks(_ job: inout Job, totalDuration: Double) {
        guard let slices = job.mix?.slices else { return }
        let existing = job.tracks
        job.tracks = SetIdentifier.toTracks(MatchMerger.merge(slices, totalDuration: totalDuration)).map { fresh in
            guard var kept = existing.first(where: { $0.start == fresh.start && $0.query == fresh.query }) else { return fresh }
            kept.index = fresh.index
            return kept
        }
    }

    /// Downloads queued tracks, `options.concurrency` at a time, until the queue is closed.
    private func downloadSettled(_ queue: AsyncStream<Track>, into dir: URL, state: Locked<Job>,
                                 publish: @escaping @Sendable () -> Void, checkpoint: @escaping @Sendable () -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for await track in queue {
                if running >= max(1, downloader.options.concurrency) {
                    await group.next()
                    running -= 1
                }
                running += 1
                group.addTask { await download(track, into: dir, state: state, publish: publish, checkpoint: checkpoint) }
            }
        }
    }

    private func download(_ track: Track, into dir: URL, state: Locked<Job>,
                          publish: @escaping @Sendable () -> Void, checkpoint: @escaping @Sendable () -> Void) async {
        @Sendable func update(_ body: (inout Track) -> Void) {
            state.mutate { job in
                guard let i = job.tracks.firstIndex(where: { $0.id == track.id }) else { return }
                body(&job.tracks[i])
            }
        }
        guard !Task.isCancelled else {
            update { $0.status = .cancelled }
            return
        }
        update { $0.status = .searching }
        publish()
        // The index may have moved since the track was queued; download under the current one.
        let current = state.value.tracks.first { $0.id == track.id } ?? track
        let result = await downloader.download(track: current, into: dir) { text in
            let changed = state.mutate { job -> Bool in
                guard let i = job.tracks.firstIndex(where: { $0.id == track.id }), job.tracks[i].activity != text else { return false }
                job.tracks[i].activity = text
                if text.hasPrefix("Downloading") || text.hasPrefix("Converting") || text.hasPrefix("Adding") {
                    job.tracks[i].status = .downloading
                }
                return true
            }
            if changed { publish() }
        }
        switch result {
        case let .success(url):
            update {
                $0.outputPath = url.path
                if downloader.analyzer != nil {
                    $0.status = .analyzing
                    $0.activity = "Analysing BPM and key"
                }
            }
            publish()
            let analysis = await downloader.analyzer?(url)
            update {
                $0.status = .done
                $0.activity = nil
                $0.note = nil
                if let analysis {
                    $0.bpm = analysis.bpm
                    $0.key = analysis.camelot
                    $0.keyName = analysis.keyName
                }
            }
        case .failure(.cancelled):
            update { $0.status = .cancelled; $0.activity = nil }
        case let .failure(error):
            update { $0.status = .failed; $0.activity = nil; $0.note = Downloader.describe(error) }
        }
        checkpoint()
    }
}

/// A value behind a lock, for state shared between the identification loop and the downloads.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    @discardableResult
    func mutate<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&stored) }
    }
}
