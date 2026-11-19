import AVFoundation
import XCTest
@testable import SetlistCore

final class SetRunnerTests: XCTestCase {
    private var root: URL!
    private var store: JobStore!
    private let a = Hit(shazamID: "A", title: "Right Now", artist: "NewJeans", confidence: nil)
    private let b = Hit(shazamID: "B", title: "LEFT RIGHT", artist: "XG", confidence: nil)
    private let c = Hit(shazamID: "C", title: "Gabriela", artist: "KATSEYE", confidence: nil)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SetRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = JobStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A runner whose "yt-dlp" writes a sine WAV for the mix and reports a file path for every song.
    private func makeRunner(mixSeconds: Double) -> FakeRunner {
        let runner = FakeRunner()
        runner.fallback = { call in
            guard let o = call.arguments.firstIndex(of: "-o") else { return .ok() }
            let output = call.arguments[o + 1]
            if output.hasSuffix(MixState.fileName) {
                try? TestAudio.writeSine(to: URL(fileURLWithPath: output), seconds: mixSeconds, sampleRate: 44_100)
                return .ok()
            }
            return .ok(output.replacingOccurrences(of: ".%(ext)s", with: ".mp3") + "\n")
        }
        return runner
    }

    private func makeSetRunner(_ runner: FakeRunner, matcher: SliceMatching) throws -> SetRunner {
        let locator = try TestTools.locator()
        var setRunner = SetRunner(fetcher: MixFetcher(runner: runner, locator: locator), matcher: matcher,
                                  downloader: Downloader(runner: runner, locator: locator), store: store)
        setRunner.delay = .zero
        setRunner.retryDelay = .zero
        return setRunner
    }

    private func makeJob() -> Job {
        Job(name: "mix", kind: .youtubeSet, sourceURL: URL(string: "https://www.youtube.com/watch?v=abc"), tracks: [])
    }

    func testIdentifiesDownloadsAndCleansUp() async throws {
        // 6 slices of 30 s: A A B B C C.
        let runner = makeRunner(mixSeconds: 180)
        let setRunner = try makeSetRunner(runner, matcher: FakeMatcher(hits: [a, a, b, b, c, c]))
        let seen = Locked([Int]())
        let finished = await setRunner.run(job: makeJob()) { job in seen.mutate { $0.append(job.tracks.count) } }

        XCTAssertEqual(finished.mix?.phase, .finished)
        XCTAssertNil(finished.mix?.message)
        XCTAssertEqual(finished.tracks.map(\.query), ["NewJeans - Right Now", "XG - LEFT RIGHT", "KATSEYE - Gabriela"])
        XCTAssertEqual(finished.tracks.map(\.start), [0, 60, 120])
        XCTAssertEqual(finished.tracks.map(\.status), [.done, .done, .done])
        // The list grew while the run was going, not only at the end.
        XCTAssertTrue(seen.value.contains(1) && seen.value.contains(2), "\(seen.value)")
        let dir = root.appendingPathComponent("mix")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(MixState.fileName).path))
        let saved = try store.loadAll().first
        XCTAssertEqual(saved?.tracks, finished.tracks)
        XCTAssertEqual(saved?.mix, finished.mix)
    }

    func testAnalysisIsStoredOnTracksFoundWhileListening() async throws {
        let runner = makeRunner(mixSeconds: 180)
        let locator = try TestTools.locator()
        let downloader = Downloader(runner: runner, locator: locator) { _ in
            TrackAnalysis(bpm: 100, camelot: "3A", keyName: "A# minor")
        }
        var setRunner = SetRunner(fetcher: MixFetcher(runner: runner, locator: locator),
                                  matcher: FakeMatcher(hits: [a, a, b, b, c, c]), downloader: downloader, store: store)
        setRunner.delay = .zero
        let finished = await setRunner.run(job: makeJob()) { _ in }
        XCTAssertEqual(finished.tracks.map(\.bpm), [100, 100, 100])
        XCTAssertEqual(finished.tracks.map(\.key), ["3A", "3A", "3A"])
        XCTAssertEqual(try store.loadAll().first?.tracks.map(\.bpm), [100, 100, 100])
    }

    func testKeepMixRenamesTheAudio() async throws {
        var setRunner = try makeSetRunner(makeRunner(mixSeconds: 60), matcher: FakeMatcher(hits: [a, a]))
        setRunner.keepMix = true
        _ = await setRunner.run(job: makeJob()) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("mix/\(MixState.keptFileName)").path))
    }

    func testPreflightFailureStopsBeforeAnyDownload() async throws {
        let runner = makeRunner(mixSeconds: 180)
        var setRunner = try makeSetRunner(runner, matcher: FakeMatcher(hits: [a]))
        setRunner.preflight = { throw URLError(.notConnectedToInternet) }
        let finished = await setRunner.run(job: makeJob()) { _ in }
        XCTAssertEqual(runner.calls.count, 0)
        XCTAssertEqual(finished.mix?.phase, .downloadingAudio)
        XCTAssertTrue(finished.mix?.message?.contains("Nothing was downloaded") ?? false, finished.mix?.message ?? "nil")
        XCTAssertTrue(finished.canResumeMix)
    }

    func testStopsAfterRepeatedMatcherFailuresAndResumesFromCheckpoint() async throws {
        let runner = makeRunner(mixSeconds: 180)
        // Calls 0-1 succeed, then calls 2, 3, 4 (three attempts at the third slice) fail.
        let failing = FakeMatcher(hits: [a, a], failOn: [2, 3, 4])
        let stopped = await (try makeSetRunner(runner, matcher: failing)).run(job: makeJob()) { _ in }
        XCTAssertEqual(failing.callCount, 5)
        XCTAssertEqual(stopped.mix?.phase, .identifying)
        XCTAssertEqual(stopped.mix?.slices.count, 2)
        XCTAssertTrue(stopped.mix?.message?.contains("Stopped at 01:00") ?? false, stopped.mix?.message ?? "nil")
        XCTAssertEqual(stopped.tracks.map(\.query), ["NewJeans - Right Now"])
        XCTAssertTrue(stopped.canResumeMix)
        XCTAssertEqual(try store.loadAll().first?.mix?.slices.count, 2, "checkpoint must be on disk")

        // Resume: the mix is not downloaded again and only the four remaining slices are matched.
        let mixDownloads = runner.calls.filter { $0.arguments.contains { $0.hasSuffix(MixState.fileName) } }.count
        let healthy = FakeMatcher(hits: [b, b, c, c])
        let finished = await (try makeSetRunner(runner, matcher: healthy)).run(job: stopped) { _ in }
        XCTAssertEqual(healthy.callCount, 4)
        XCTAssertEqual(runner.calls.filter { $0.arguments.contains { $0.hasSuffix(MixState.fileName) } }.count, mixDownloads)
        XCTAssertEqual(finished.mix?.phase, .finished)
        XCTAssertNil(finished.mix?.message)
        XCTAssertEqual(finished.tracks.map(\.query), ["NewJeans - Right Now", "XG - LEFT RIGHT", "KATSEYE - Gabriela"])
        XCTAssertEqual(finished.tracks.map(\.status), [.done, .done, .done])
    }

    func testCancellationKeepsTheCheckpoint() async throws {
        let runner = makeRunner(mixSeconds: 300)
        var setRunner = try makeSetRunner(runner, matcher: FakeMatcher(hits: Array(repeating: a, count: 10)))
        setRunner.delay = .milliseconds(150)
        let job = makeJob()
        let heard = Locked(0)
        let task = Task { await setRunner.run(job: job) { job in heard.mutate { $0 = job.mix?.slices.count ?? 0 } } }
        // Stop once a couple of slices are in, however long the fake mix took to write.
        for _ in 0..<400 where heard.value < 2 { try await Task.sleep(for: .milliseconds(50)) }
        task.cancel()
        let stopped = await task.value
        XCTAssertEqual(stopped.mix?.phase, .identifying)
        XCTAssertNil(stopped.mix?.message, "a stop the user asked for is not an error")
        let slices = stopped.mix?.slices.count ?? 0
        XCTAssertTrue(slices > 0 && slices < 10, "\(slices)")
        XCTAssertFalse(stopped.hasActiveTracks)
    }

    func testCanonicalURLDropsPlaylistNoise() {
        let messy = URL(string: "https://www.youtube.com/watch?v=TrR1cND-gjQ&list=RDTrR1cND-gjQ&start_radio=1=")!
        XCTAssertEqual(MixFetcher.canonicalURL(messy).absoluteString, "https://www.youtube.com/watch?v=TrR1cND-gjQ")
        let short = URL(string: "https://youtu.be/TrR1cND-gjQ?t=10")!
        XCTAssertEqual(MixFetcher.canonicalURL(short), short)
    }
}
