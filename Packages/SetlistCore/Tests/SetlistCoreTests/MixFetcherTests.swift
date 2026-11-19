import XCTest
@testable import SetlistCore

final class MixFetcherTests: XCTestCase {
    private var locator: ToolLocator!
    private let url = URL(string: "https://www.youtube.com/watch?v=abc123&list=PL9")!

    override func setUpWithError() throws {
        locator = try TestTools.locator()
    }

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "mix-info", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testParseInfoExtractsCommentsTitleDuration() throws {
        let info = try MixFetcher.parseInfo(try fixture())
        XCTAssertEqual(info.title, "K-Pop R&B Remix Mix 2025 ✨")
        XCTAssertEqual(info.duration, 2232.5)
        XCTAssertTrue(info.description.hasPrefix("💿 Track List\n00:00 NewJeans"))
        XCTAssertEqual(info.comments, ["fire mix 🔥", "tracklist?\n00:00 A - B\n01:30 C - D\n03:50 E - F"])
    }

    func testParseInfoToleratesMissingComments() throws {
        let data = Data(#"{"title":"T","description":"","duration":10}"#.utf8)
        let info = try MixFetcher.parseInfo(data)
        XCTAssertEqual(info, MixInfo(title: "T", description: "", duration: 10, comments: []))
    }

    func testInfoArgumentsLimitComments() {
        XCTAssertEqual(MixFetcher.infoArguments(url: url), [
            "-J", "--no-playlist", "--write-comments",
            "--extractor-args", "youtube:max_comments=100,all,0,0;comment_sort=top",
            url.absoluteString,
        ])
    }

    func testAudioArgumentsProduceMonoWav() {
        let out = URL(fileURLWithPath: "/work/mix.wav")
        let ffmpeg = URL(fileURLWithPath: "/tools/ffmpeg")
        XCTAssertEqual(MixFetcher.audioArguments(url: url, output: out, ffmpeg: ffmpeg), [
            "--no-playlist", "-f", "bestaudio/best", "-x", "--audio-format", "wav",
            "--postprocessor-args", "ffmpeg:-ar 44100 -ac 1",
            "--ffmpeg-location", "/tools",
            "-o", "/work/mix.wav",
            url.absoluteString,
        ])
    }

    func testFetchInfoRunsYtDlpAndParses() async throws {
        let runner = FakeRunner(results: [.ok(String(decoding: try fixture(), as: UTF8.self))])
        let fetcher = MixFetcher(runner: runner, locator: locator)
        let info = try await fetcher.fetchInfo(url: url)
        XCTAssertEqual(info.title, "K-Pop R&B Remix Mix 2025 ✨")
        XCTAssertEqual(runner.calls.first?.executable, "yt-dlp")
        XCTAssertEqual(runner.calls.first?.arguments.first, "-J")
    }

    func testFetchInfoFailureSurfacesStderr() async throws {
        let runner = FakeRunner(results: [.fail("Video unavailable")])
        let fetcher = MixFetcher(runner: runner, locator: locator)
        do {
            _ = try await fetcher.fetchInfo(url: url)
            XCTFail("expected throw")
        } catch let error as ToolError {
            XCTAssertEqual(error, .failed(.ytDlp, exitCode: 1, stderr: "This video is no longer available."))
        }
    }

    func testFetchAudioFailureThrows() async throws {
        let runner = FakeRunner(results: [.fail("403")])
        let fetcher = MixFetcher(runner: runner, locator: locator)
        do {
            try await fetcher.fetchAudio(url: url, to: URL(fileURLWithPath: "/tmp/x.wav"), onLine: nil)
            XCTFail("expected throw")
        } catch let error as ToolError {
            XCTAssertEqual(error, .failed(.ytDlp, exitCode: 1, stderr: "403"))
        }
    }

    func testCutArguments() async throws {
        let runner = FakeRunner()
        let ffmpeg = FFmpeg(runner: runner, locator: locator)
        try await ffmpeg.cut(input: URL(fileURLWithPath: "/work/mix.wav"), start: 100, length: 40, output: URL(fileURLWithPath: "/work/seg.wav"))
        XCTAssertEqual(runner.calls.first?.executable, "ffmpeg")
        XCTAssertEqual(runner.calls.first?.arguments, [
            "-y", "-hide_banner", "-loglevel", "error",
            "-ss", "100", "-t", "40", "-i", "/work/mix.wav", "-ar", "44100", "-ac", "1", "/work/seg.wav",
        ])
    }

    func testWriteTagsRewritesFileInPlace() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp3 = dir.appendingPathComponent("01 - A - B.mp3")
        try Data("original".utf8).write(to: mp3)

        let runner = FakeRunner()
        runner.fallback = { call in
            // Simulate ffmpeg writing the temp output named by the last argument.
            try? Data("tagged".utf8).write(to: URL(fileURLWithPath: call.arguments.last!))
            return .ok()
        }
        let ffmpeg = FFmpeg(runner: runner, locator: locator)
        try await ffmpeg.writeTags(file: mp3, bpm: 128, key: "Am")

        let args = runner.calls.first!.arguments
        XCTAssertEqual(Array(args.prefix(13)), ["-y", "-hide_banner", "-loglevel", "error", "-i", mp3.path, "-map", "0", "-c", "copy", "-id3v2_version", "3", "-metadata"])
        XCTAssertTrue(args.contains("TBPM=128"))
        XCTAssertTrue(args.contains("TKEY=Am"))
        XCTAssertTrue(args.last!.hasSuffix(".mp3"))
        XCTAssertNotEqual(args.last!, mp3.path)
        XCTAssertEqual(try String(contentsOf: mp3, encoding: .utf8), "tagged")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 1)
    }

    func testWriteTagsFailureKeepsOriginal() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp3 = dir.appendingPathComponent("x.mp3")
        try Data("original".utf8).write(to: mp3)
        let ffmpeg = FFmpeg(runner: FakeRunner(results: [.fail("bad")]), locator: locator)
        await XCTAssertThrowsErrorAsync(try await ffmpeg.writeTags(file: mp3, bpm: 1, key: "C"))
        XCTAssertEqual(try String(contentsOf: mp3, encoding: .utf8), "original")
    }

    func testDurationParsesFfmpegBanner() async throws {
        let banner = "Input #0, wav, from 'mix.wav':\n  Duration: 00:37:12.50, bitrate: 705 kb/s\n"
        let runner = FakeRunner(results: [CommandResult(exitCode: 1, stdout: "", stderr: banner)])
        let ffmpeg = FFmpeg(runner: runner, locator: locator)
        let duration = try await ffmpeg.duration(of: URL(fileURLWithPath: "/work/mix.wav"))
        XCTAssertEqual(duration, 2232.5)
    }
}


func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
