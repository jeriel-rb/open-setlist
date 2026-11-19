import XCTest
@testable import SetlistCore

final class FileNameFormatTests: XCTestCase {
    func testStandardMatchesTheOriginalNaming() {
        let format = FileNameFormat.standard
        XCTAssertEqual(format.stem(index: 3, query: "XG - LEFT RIGHT"), "03 - XG - LEFT RIGHT")
        XCTAssertEqual(format.stem(index: 12, query: "https://youtu.be/abc"), "12 - %(title).120B")
        XCTAssertEqual(format.stem(index: 1, query: "XG / LEFT RIGHT"), Track(index: 1, query: "XG / LEFT RIGHT").fileStem)
    }

    func testOrderCanBeChangedAndPartsLeftOut() {
        var format = FileNameFormat.standard
        format.order = [.title, .artist, .number]
        XCTAssertEqual(format.stem(index: 3, query: "XG - LEFT RIGHT"), "LEFT RIGHT - XG - 03")
        format.included = [.artist, .title]
        format.order = [.number, .artist, .title]
        XCTAssertEqual(format.stem(index: 3, query: "XG - LEFT RIGHT"), "XG - LEFT RIGHT")
        format.included = [.title]
        XCTAssertEqual(format.stem(index: 3, query: "XG - LEFT RIGHT"), "LEFT RIGHT")
    }

    func testSeparatorNumberStylePrefixAndSuffix() {
        var format = FileNameFormat.standard
        format.separator = "_"
        format.numberDigits = 3
        format.prefix = "Mix "
        format.suffix = " [320]"
        XCTAssertEqual(format.stem(index: 7, query: "XG - LEFT RIGHT"), "Mix 007_XG_LEFT RIGHT [320]")
        format.numberDigits = 1
        XCTAssertEqual(format.stem(index: 7, query: "XG - LEFT RIGHT"), "Mix 7_XG_LEFT RIGHT [320]")
    }

    func testQueryWithoutAnArtistIsAllTitle() {
        var format = FileNameFormat.standard
        XCTAssertEqual(format.stem(index: 2, query: "Lucid Dream"), "02 - Lucid Dream")
        // Asking for the artist alone must still name the file.
        format.included = [.artist]
        XCTAssertEqual(format.stem(index: 2, query: "Lucid Dream"), "Lucid Dream")
        XCTAssertEqual(format.stem(index: 2, query: "aespa - Lucid Dream"), "aespa")
    }

    func testOnlyTheFirstDashSplitsArtistFromTitle() {
        var format = FileNameFormat.standard
        format.order = [.title, .artist, .number]
        format.included = [.title, .artist]
        XCTAssertEqual(format.stem(index: 1, query: "NewJeans - Right Now - R&B Remix"), "Right Now - R&B Remix - NewJeans")
    }

    func testLinksUseTheVideoTitleOnceWhereTheNameGoes() {
        var format = FileNameFormat.standard
        format.order = [.title, .artist, .number]
        format.prefix = "100% "
        XCTAssertEqual(format.stem(index: 4, query: "https://youtu.be/abc"), "100%% %(title).120B - 04")
    }

    func testUnsafeCharactersAndPercentAreHandled() {
        var format = FileNameFormat.standard
        format.prefix = "a/b: "
        XCTAssertEqual(format.stem(index: 1, query: "Crystal Waters - 100% Pure Love"), "a-b- 01 - Crystal Waters - 100%% Pure Love")
    }

    func testNumberAloneIsAllowedButAMissingArtistFallsBackToTheTitle() {
        var format = FileNameFormat.standard
        format.included = [.number]
        XCTAssertEqual(format.stem(index: 4, query: "XG - LEFT RIGHT"), "04")
        format.included = [.number, .artist]
        XCTAssertEqual(format.stem(index: 4, query: "Lucid Dream"), "04 - Lucid Dream")
    }

    func testNothingIncludedFallsBackToTheTitle() {
        var format = FileNameFormat.standard
        format.included = []
        XCTAssertEqual(format.stem(index: 1, query: "XG - LEFT RIGHT"), "LEFT RIGHT")
    }

    func testExampleAndCodableRoundTrip() throws {
        var format = FileNameFormat.standard
        XCTAssertEqual(format.example, "01 - XG - LEFT RIGHT.mp3")
        format.order = [.artist, .title, .number]
        format.suffix = " (set)"
        let decoded = try JSONDecoder().decode(FileNameFormat.self, from: JSONEncoder().encode(format))
        XCTAssertEqual(decoded, format)
        XCTAssertEqual(decoded.example, "XG - LEFT RIGHT - 01 (set).mp3")
    }

    func testDownloaderUsesTheFormat() async throws {
        let runner = FakeRunner()
        runner.fallback = { _ in .ok("/tmp/x.mp3\n") }
        var options = DownloadOptions()
        options.fileNameFormat.included = [.artist, .title]
        let downloader = Downloader(runner: runner, locator: try TestTools.locator(), options: options)
        _ = await downloader.download(track: Track(index: 5, query: "XG - LEFT RIGHT"), into: URL(fileURLWithPath: "/tmp/out"))
        let args = runner.calls[0].arguments
        XCTAssertEqual(args[args.firstIndex(of: "-o")! + 1], "/tmp/out/XG - LEFT RIGHT.%(ext)s")
    }
}
