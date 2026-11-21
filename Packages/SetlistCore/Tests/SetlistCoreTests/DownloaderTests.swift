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
            "--socket-timeout", "30", "--retries", "3", "--fragment-retries", "3",
            "--ffmpeg-location", "/tools", "--print", "after_move:webpage_url", "--print", "after_move:filepath",
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

    func testSearchesBothSitesAndDownloadsTheBestMatch() async throws {
        let runner = FakeRunner()
        runner.searchResult = nil
        let path = "\(root.path)/01 - A - B (X Remix).mp3"
        runner.fallback = { call in
            switch call.arguments.last ?? "" {
            case "ytsearch5:A - B (X Remix)":
                return .ok(#"{"title": "A - B (Official Video)", "uploader": "A", "duration": 200, "webpage_url": "https://youtube.com/watch?v=orig"}"# + "\n")
            case "scsearch5:A - B (X Remix)":
                return .ok(#"{"title": "A - B (X Remix)", "uploader": "X", "duration": 210, "webpage_url": "https://soundcloud.com/x/a-b-x-remix"}"# + "\n")
            default:
                return .ok("https://soundcloud.com/x/a-b-x-remix\n" + path + "\n")
            }
        }
        let seen = LineCollector()
        let result = await Downloader(runner: runner, locator: locator)
            .fetch(track: Track(index: 1, query: "A - B (X Remix)"), into: root) { seen.append($0) }
        XCTAssertEqual(try result.get(), Downloader.Downloaded(file: URL(fileURLWithPath: path), source: "https://soundcloud.com/x/a-b-x-remix"))
        XCTAssertEqual(runner.calls.count, 3)
        XCTAssertEqual(Set(runner.calls.prefix(2).compactMap(\.arguments.last)), ["ytsearch5:A - B (X Remix)", "scsearch5:A - B (X Remix)"])
        XCTAssertTrue(runner.calls[0].arguments.contains("--flat-playlist"))
        XCTAssertEqual(runner.calls[2].arguments.last, "https://soundcloud.com/x/a-b-x-remix")
        XCTAssertEqual(seen.lines.first, "Searching YouTube and SoundCloud")
    }

    func testNextBestMatchIsTriedWhenTheBestFails() async throws {
        let runner = FakeRunner()
        runner.searchResult = nil
        let path = "\(root.path)/01 - A - B.mp3"
        runner.fallback = { call in
            switch call.arguments.last ?? "" {
            case "ytsearch5:A - B":
                return .ok(#"{"title": "A - B", "webpage_url": "https://youtube.com/watch?v=1"}"# + "\n" + #"{"title": "A - B (Live)", "webpage_url": "https://youtube.com/watch?v=2"}"# + "\n")
            case "scsearch5:A - B":
                return .ok(#"{"title": "A - B", "webpage_url": "https://soundcloud.com/a/b"}"# + "\n")
            case "https://youtube.com/watch?v=1":
                return .fail("blocked")
            default:
                return .ok(path + "\n")
            }
        }
        let result = await Downloader(runner: runner, locator: locator).download(track: Track(index: 1, query: "A - B"), into: root)
        XCTAssertEqual(try result.get().path, path)
        XCTAssertEqual(runner.calls.dropFirst(2).compactMap(\.arguments.last), ["https://youtube.com/watch?v=1", "https://soundcloud.com/a/b"])
    }

    func testLeftoversOfAFailedAttemptAreRemoved() async throws {
        let runner = FakeRunner(results: [.fail("blocked"), .ok("\(root.path)/01 - A - B.mp3\n")])
        let fm = FileManager.default
        // What a failed first attempt leaves behind, next to files that must stay.
        for name in ["01 - A - B.webp", "01 - A - B.f251.webm.part", "01 - A - B.mp3", "01 - A - B. Part 2.webm.part", "02 - C - D.webp"] {
            fm.createFile(atPath: root.appendingPathComponent(name).path, contents: Data())
        }
        _ = await Downloader(runner: runner, locator: locator).download(track: Track(index: 1, query: "A - B"), into: root)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).sorted(),
                       ["01 - A - B. Part 2.webm.part", "01 - A - B.mp3", "02 - C - D.webp"])
    }

    func testLinksAreNotSearchedFor() async {
        let runner = FakeRunner()
        _ = await Downloader(runner: runner, locator: locator).download(track: Track(index: 1, query: "https://youtu.be/abc"), into: root)
        XCTAssertEqual(runner.calls.compactMap(\.arguments.last), ["https://youtu.be/abc"])
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

    func testActivityDescribesYtDlpLines() {
        XCTAssertEqual(Downloader.activity(for: "[download]  45.2% of    3.67MiB at    2.76MiB/s ETA 00:01"), "Downloading 45%")
        XCTAssertEqual(Downloader.activity(for: "[download] 100% of 3.67MiB in 00:00:01"), "Downloading 100%")
        XCTAssertEqual(Downloader.activity(for: "[ExtractAudio] Destination: /x/01 - a.mp3"), "Converting to MP3")
        XCTAssertEqual(Downloader.activity(for: "[Metadata] Adding metadata to \"/x/01 - a.mp3\""), "Adding cover and tags")
        XCTAssertEqual(Downloader.activity(for: "[EmbedThumbnail] ffmpeg: Adding thumbnail"), "Adding cover and tags")
        XCTAssertEqual(Downloader.activity(for: "[youtube:search] query: Downloading web client config"), "Searching YouTube")
        XCTAssertEqual(Downloader.activity(for: "[youtube] abc: Downloading webpage"), "Getting the song's details")
        XCTAssertEqual(Downloader.activity(for: "[soundcloud:search] query: Downloading search page"), "Searching SoundCloud")
        XCTAssertNil(Downloader.activity(for: "random noise"))
    }

    func testSourcePageIsStoredOnTheTrack() async throws {
        let runner = FakeRunner()
        let path = "\(root.path)/set/01 - A - B.mp3"
        runner.fallback = { _ in .ok("https://www.youtube.com/watch?v=abc123\n" + path + "\n") }
        let store = JobStore(root: root)
        var job = Job(name: "set", kind: .pasteList, tracks: [Track(index: 1, query: "A - B")])
        _ = try store.directory(for: &job)
        let finished = await Downloader(runner: runner, locator: locator).downloadAll(job: job, store: store) { _ in }
        XCTAssertEqual(finished.tracks[0].status, .done)
        XCTAssertEqual(finished.tracks[0].outputPath, path)
        XCTAssertEqual(finished.tracks[0].sourceURL, "https://www.youtube.com/watch?v=abc123")
    }

    func testDownloadFraction() {
        XCTAssertEqual(Downloader.downloadFraction(in: "[download]  45.2% of 3.1MiB at 1MiB/s"), 0.452)
        XCTAssertEqual(Downloader.downloadFraction(in: "[download] 100% of 3.1MiB"), 1)
        XCTAssertNil(Downloader.downloadFraction(in: "[download] Destination: a.webm"))
        XCTAssertNil(Downloader.downloadFraction(in: "[ExtractAudio] 50% done"))
    }

    func testDownloadAllReportsActivityPerTrack() async throws {
        let runner = FakeRunner()
        runner.streamed = [0: ["[youtube:search] q: Downloading", "[download]  50.0% of 1MiB", "[ExtractAudio] Destination: x.mp3", "\(root.path)/set/01 - A - B.mp3"]]
        let path = "\(root.path)/set/01 - A - B.mp3"
        runner.fallback = { _ in .ok(path + "\n") }
        let store = JobStore(root: root)
        var job = Job(name: "set", kind: .pasteList, tracks: [Track(index: 1, query: "A - B")])
        _ = try store.directory(for: &job)
        let seen = LineCollector()
        let finished = await Downloader(runner: runner, locator: locator).downloadAll(job: job, store: store) { track in
            seen.append(track.activity ?? "-")
        }
        XCTAssertEqual(finished.tracks[0].status, .done)
        XCTAssertNil(finished.tracks[0].activity)
        XCTAssertTrue(seen.lines.contains("Searching YouTube"), "\(seen.lines)")
        XCTAssertTrue(seen.lines.contains("Downloading 50%"), "\(seen.lines)")
        XCTAssertTrue(seen.lines.contains("Converting to MP3"), "\(seen.lines)")
    }

    func testRepeatedProgressLineIsReportedOnce() async throws {
        let runner = FakeRunner()
        runner.streamed = [0: ["[download]  50.0% of 1MiB", "[download]  50.4% of 1MiB", "[download]  50.9% of 1MiB", "[download]  51.0% of 1MiB"]]
        let path = "\(root.path)/set/01 - A - B.mp3"
        runner.fallback = { _ in .ok(path + "\n") }
        let store = JobStore(root: root)
        var job = Job(name: "set", kind: .pasteList, tracks: [Track(index: 1, query: "A - B")])
        _ = try store.directory(for: &job)
        let seen = LineCollector()
        _ = await Downloader(runner: runner, locator: locator).downloadAll(job: job, store: store) { track in
            seen.append(track.activity ?? "-")
        }
        XCTAssertEqual(seen.lines.filter { $0 == "Downloading 50%" }.count, 1, "\(seen.lines)")
        XCTAssertEqual(seen.lines.filter { $0 == "Downloading 51%" }.count, 1, "\(seen.lines)")
    }

    func testDownloadAllCancellationMarksRemainingTracks() async throws {
        let runner = FakeRunner()
        runner.fallback = { _ in .ok("") }
        runner.delay = .seconds(5)
        let store = JobStore(root: root)
        var job = Job(name: "set", kind: .pasteList, tracks: (1...4).map { Track(index: $0, query: "T\($0) - S") })
        _ = try store.directory(for: &job)
        var options = DownloadOptions()
        options.concurrency = 1
        let downloader = Downloader(runner: runner, locator: locator, options: options)
        let task = Task { await downloader.downloadAll(job: job, store: store) { _ in } }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let finished = await task.value
        XCTAssertEqual(finished.tracks.filter { $0.status == .cancelled }.count, 4, "\(finished.tracks.map(\.status))")
        XCTAssertLessThanOrEqual(runner.calls.count, 2)
        XCTAssertEqual(try store.loadAll().first?.tracks.map(\.status), finished.tracks.map(\.status))
    }

    func testDownloadAllRunsAnalyzerAfterDownload() async throws {
        let runner = FakeRunner()
        runner.fallback = { call in
            let stem = call.arguments[call.arguments.firstIndex(of: "-o")! + 1].replacingOccurrences(of: ".%(ext)s", with: ".mp3")
            return .ok(stem + "\n")
        }
        let store = JobStore(root: root)
        var job = Job(name: "set", kind: .pasteList, tracks: [Track(index: 1, query: "A - B")])
        _ = try store.directory(for: &job)
        let analyzed = LineCollector()
        let seen = LineCollector()
        let downloader = Downloader(runner: runner, locator: locator, analyzer: { url in
            analyzed.append(url.lastPathComponent)
            return TrackAnalysis(bpm: 128, camelot: "8A", keyName: "A minor")
        })
        let finished = await downloader.downloadAll(job: job, store: store) { track in
            seen.append("\(track.status.rawValue):\(track.activity ?? "-")")
        }
        XCTAssertEqual(analyzed.lines, ["01 - A - B.mp3"])
        XCTAssertEqual(finished.tracks[0].bpm, 128)
        XCTAssertEqual(finished.tracks[0].key, "8A")
        XCTAssertEqual(finished.tracks[0].keyName, "A minor")
        XCTAssertTrue(seen.lines.contains("analyzing:Analysing BPM and key"), "\(seen.lines)")
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

    func testLiveBestMatchesNameTheVersionAskedFor() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SETLIST_LIVE"] == "1", "set SETLIST_LIVE=1 to run")
        let repoBin = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bin")
        let live = ToolLocator(overrideDir: nil, bundleBinDir: repoBin, searchPaths: [])
        let downloader = Downloader(runner: ProcessRunner(), locator: live)
        let ytDlp = try live.url(for: .ytDlp)
        for query in ["NewJeans - Right Now (R&B Remix)", "XG - LEFT RIGHT", "Fred again.. - Delilah (pull me out of this)"] {
            let matches = await downloader.bestMatches(for: query, ytDlp: ytDlp)
            print("LIVE \(query) -> \(matches)")
            XCTAssertFalse(matches.isEmpty, query)
        }
    }

    // MARK: Refusals that pass, names read at download time, how many at once

    func testARefusalThatPassesIsTriedAgainAtTheSamePage() async throws {
        let path = root.appendingPathComponent("01 - x.mp3").path
        let runner = FakeRunner(results: [.fail("ERROR: unable to download video data: HTTP Error 403: Forbidden"), .ok("https://youtu.be/abc\n\(path)\n")])
        var options = DownloadOptions()
        options.retryPause = .zero
        let result = await Downloader(runner: runner, locator: locator, options: options)
            .fetch(track: Track(index: 1, query: "https://youtu.be/abc"), into: root)
        XCTAssertEqual(try result.get().file.path, path)
        XCTAssertEqual(runner.calls.compactMap(\.arguments.last), ["https://youtu.be/abc", "https://youtu.be/abc"])
    }

    func testARefusalIsGivenUpOnAfterThreeTriesAndOtherFailuresAreNotRepeated() async {
        var options = DownloadOptions()
        options.retryPause = .zero
        let refusing = FakeRunner()
        refusing.fallback = { _ in .fail("HTTP Error 403: Forbidden") }
        let refused = await Downloader(runner: refusing, locator: locator, options: options)
            .fetch(track: Track(index: 1, query: "https://youtu.be/abc"), into: root)
        XCTAssertEqual(refused, .failure(.allSourcesFailed(lastStderr: "HTTP Error 403: Forbidden")))
        XCTAssertEqual(refusing.calls.count, 3)

        let gone = FakeRunner()
        gone.fallback = { _ in .fail("ERROR: Video unavailable") }
        _ = await Downloader(runner: gone, locator: locator, options: options)
            .fetch(track: Track(index: 1, query: "https://youtu.be/abc"), into: root)
        XCTAssertEqual(gone.calls.count, 1)
    }

    func testASoundCloudLinkWithoutANameHasItReadBeforeTheDownload() async throws {
        let runner = FakeRunner()
        runner.nameResult = { _ in .ok(#"{"id":"1","webpage_url":"https://soundcloud.com/caes/mamushi","uploader":"C A E S","title":"Mamushi (Caes Edit)"}"# + "\n") }
        runner.fallback = { call in
            let template = call.arguments[call.arguments.firstIndex(of: "-o")! + 1]
            return .ok("https://soundcloud.com/caes/mamushi\n" + template.replacingOccurrences(of: ".%(ext)s", with: ".mp3") + "\n")
        }
        let downloader = Downloader(runner: runner, locator: locator)
        let result = try await downloader.fetch(track: Track(index: 4, query: "https://soundcloud.com/caes/mamushi"), into: root).get()
        XCTAssertEqual(result.file.lastPathComponent, "04 - C A E S - Mamushi (Caes Edit).mp3")
        XCTAssertEqual(result.name, "C A E S - Mamushi (Caes Edit)")

        // A name that is already known is not read again, and a YouTube link keeps using its own title.
        runner.nameResult = { _ in XCTFail("no name lookup expected"); return .ok("") }
        var named = Track(index: 5, query: "https://soundcloud.com/a/b")
        named.songName = "A - B"
        let known = try await downloader.fetch(track: named, into: root).get()
        XCTAssertEqual(known.file.lastPathComponent, "05 - A - B.mp3")
        XCTAssertNil(known.name)
        let tube = try await downloader.fetch(track: Track(index: 6, query: "https://youtu.be/abc"), into: root).get()
        XCTAssertEqual(tube.file.lastPathComponent, "06 - %(title).120B.mp3")
    }

    func testDownloadAllRemembersANameReadAtDownloadTime() async throws {
        let runner = FakeRunner()
        runner.nameResult = { _ in .ok(#"{"id":"1","webpage_url":"https://soundcloud.com/a/b","uploader":"A","title":"B"}"# + "\n") }
        runner.fallback = { call in
            let template = call.arguments[call.arguments.firstIndex(of: "-o")! + 1]
            return .ok(template.replacingOccurrences(of: ".%(ext)s", with: ".mp3") + "\n")
        }
        let store = JobStore(root: root)
        var job = Job(name: "links", kind: .link, tracks: [Track(index: 1, query: "https://soundcloud.com/a/b")])
        _ = try store.directory(for: &job)
        let finished = await Downloader(runner: runner, locator: locator).downloadAll(job: job, store: store) { _ in }
        XCTAssertEqual(finished.tracks.first?.songName, "A - B")
        XCTAssertEqual(finished.tracks.first?.displayName, "A - B")
        // The list in the folder is written before the download; it has to end up with the name too.
        let dir = try store.directory(for: &job)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("tracklist.txt"), encoding: .utf8), "A - B\n")
    }

    func testRecommendedConcurrencyFollowsTheProcessorCount() {
        XCTAssertEqual(DownloadOptions.recommendedConcurrency(cores: 1), 2)
        XCTAssertEqual(DownloadOptions.recommendedConcurrency(cores: 4), 2)
        XCTAssertEqual(DownloadOptions.recommendedConcurrency(cores: 8), 4)
        XCTAssertEqual(DownloadOptions.recommendedConcurrency(cores: 10), 5)
        XCTAssertEqual(DownloadOptions.recommendedConcurrency(cores: 24), 6)
    }
}
