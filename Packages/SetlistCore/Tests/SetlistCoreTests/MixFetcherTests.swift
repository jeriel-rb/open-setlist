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
            XCTAssertEqual(error, .failed(.ytDlp, exitCode: 1, stderr: "Video unavailable"))
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

    func testDurationParsesFfmpegBanner() async throws {
        let banner = "Input #0, wav, from 'mix.wav':\n  Duration: 00:37:12.50, bitrate: 705 kb/s\n"
        let runner = FakeRunner(results: [CommandResult(exitCode: 1, stdout: "", stderr: banner)])
        let ffmpeg = FFmpeg(runner: runner, locator: locator)
        let duration = try await ffmpeg.duration(of: URL(fileURLWithPath: "/work/mix.wav"))
        XCTAssertEqual(duration, 2232.5)
    }
}
