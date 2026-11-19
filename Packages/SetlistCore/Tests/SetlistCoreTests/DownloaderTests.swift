import XCTest
@testable import SetlistCore

final class DownloaderTests: XCTestCase {
    private var root: URL!
    private var locator: ToolLocator!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        locator = try TestTools.locator()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTargetsForQueryAndURL() {
        XCTAssertEqual(Downloader.targets(for: "XG - LEFT RIGHT"), ["ytsearch1:XG - LEFT RIGHT", "scsearch1:XG - LEFT RIGHT"])
        XCTAssertEqual(Downloader.targets(for: "https://youtu.be/abc"), ["https://youtu.be/abc"])
    }

    func testArgumentsAlwaysIncludeNoPlaylist() {
        let ffmpeg = URL(fileURLWithPath: "/tools/ffmpeg")
        let args = Downloader.arguments(target: "https://www.youtube.com/watch?v=a&list=PL1", outputTemplate: "/out/01 - x.%(ext)s", quality: "192K", ffmpeg: ffmpeg)
        XCTAssertEqual(args, [
            "--no-playlist", "--extract-audio", "--audio-format", "mp3", "--audio-quality", "192K",
            "--embed-thumbnail", "--embed-metadata", "--no-overwrites", "--newline", "--progress",
            "--ffmpeg-location", "/tools", "--print", "after_move:filepath",
            "-o", "/out/01 - x.%(ext)s", "https://www.youtube.com/watch?v=a&list=PL1",
        ])
    }

    func testFallsBackToSoundCloudWhenYouTubeFails() async throws {
        let runner = FakeRunner(results: [.fail("no video"), .ok("[download] 100%\n\(root.path)/01 - XG - LEFT RIGHT.mp3\n")])
        let downloader = Downloader(runner: runner, locator: locator)
        let result = await downloader.download(track: Track(index: 1, query: "XG - LEFT RIGHT"), into: root)
        XCTAssertEqual(try result.get().path, "\(root.path)/01 - XG - LEFT RIGHT.mp3")
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(runner.calls[0].executable, "yt-dlp")
        XCTAssertEqual(runner.calls[0].arguments.last, "ytsearch1:XG - LEFT RIGHT")
        XCTAssertEqual(runner.calls[1].arguments.last, "scsearch1:XG - LEFT RIGHT")
        XCTAssertTrue(runner.calls[0].arguments.contains("\(root.path)/01 - XG - LEFT RIGHT.%(ext)s"))
    }

    func testAllSourcesFailedReportsLastStderr() async {
        let runner = FakeRunner(results: [.fail("first"), .fail("second")])
        let downloader = Downloader(runner: runner, locator: locator)
        let result = await downloader.download(track: Track(index: 1, query: "Nope - Nothing"), into: root)
        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .allSourcesFailed(lastStderr: "second"))
    }

    func testURLTrackIsTriedOnce() async {
        let runner = FakeRunner(results: [.fail("gone")])
        let downloader = Downloader(runner: runner, locator: locator)
        _ = await downloader.download(track: Track(index: 1, query: "https://youtu.be/abc"), into: root)
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testMissingToolIsReported() async {
        let empty = ToolLocator(overrideDir: nil, bundleBinDir: nil, searchPaths: [])
        let downloader = Downloader(runner: FakeRunner(), locator: empty)
        let result = await downloader.download(track: Track(index: 1, query: "A - B"), into: root)
        guard case let .failure(.tool(toolError)) = result, case .notFound(.ytDlp, _) = toolError else {
            return XCTFail("expected tool error, got \(result)")
        }
    }

    func testDownloadAllUpdatesStatusesAndWritesFiles() async throws {
        let runner = FakeRunner()
        runner.fallback = { call in
            let target = call.arguments.last ?? ""
            if target.contains("Middle") { return .fail("nope") }
            let stem = call.arguments[call.arguments.firstIndex(of: "-o")! + 1]
                .replacingOccurrences(of: ".%(ext)s", with: ".mp3")
            return .ok(stem + "\n")
        }
        let store = JobStore(root: root)
        var job = Job(name: "set", kind: .pasteList, tracks: [
            Track(index: 1, query: "First - Song"),
            Track(index: 2, query: "Middle - Song"),
            Track(index: 3, query: "Last - Song"),
            Track(index: 4, query: "Unknown", confidence: .low),
        ])
        _ = try store.directory(for: &job)
        let updates = LineCollector()
        let downloader = Downloader(runner: runner, locator: locator)
        let finished = await downloader.downloadAll(job: job, store: store) { track in
            updates.append("\(track.index):\(track.status.rawValue)")
        }

        XCTAssertEqual(finished.tracks.map(\.status), [.done, .failed, .done, .skipped])
        XCTAssertEqual(finished.tracks[0].outputPath, "\(root.path)/set/01 - First - Song.mp3")
        XCTAssertEqual(finished.tracks[1].note, "nope")
        XCTAssertGreaterThanOrEqual(updates.lines.count, 6)
        // Low-confidence tracks never hit yt-dlp: 2 attempts for the failed one + 1 each for the two successes.
        XCTAssertEqual(runner.calls.count, 4)

        let dir = root.appendingPathComponent("set")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("failed.txt"), encoding: .utf8), "Middle - Song\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("tracklist.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("job.json").path))
    }

    func testLiveDownloadOneTrack() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SETLIST_LIVE"] == "1", "set SETLIST_LIVE=1 to run")
        let repoBin = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bin")
        let live = ToolLocator(overrideDir: nil, bundleBinDir: repoBin, searchPaths: [])
        let downloader = Downloader(runner: ProcessRunner(), locator: live)
        let result = await downloader.download(track: Track(index: 1, query: "XG - LEFT RIGHT"), into: root)
        let file = try result.get()
        XCTAssertEqual(file.pathExtension, "mp3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
