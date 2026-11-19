import XCTest
@testable import SetlistCore

final class ValidationTests: XCTestCase {
    func testOrdinaryLinesAreFine() {
        XCTAssertNil(DraftValidation.problem(with: "XG - LEFT RIGHT", in: .text))
        XCTAssertNil(DraftValidation.problem(with: "허윤진 - 해파리", in: .text))
        XCTAssertNil(DraftValidation.problem(with: "https://youtu.be/abc123", in: .text))
        XCTAssertNil(DraftValidation.problem(with: "https://soundcloud.com/a/sets/b", in: .link))
        XCTAssertNil(DraftValidation.problem(with: "https://open.spotify.com/intl-id/track/3rUGC1vUpkDG9CZFHMur1t?si=1", in: .link))
        XCTAssertNil(DraftValidation.problem(with: "   ", in: .text))
    }

    func testTextTab() {
        XCTAssertEqual(DraftValidation.problem(with: "a", in: .text), "Too short to search for.")
        XCTAssertEqual(DraftValidation.problem(with: "🔥🔥🔥", in: .text), "Too short to search for.")
        XCTAssertNotNil(DraftValidation.problem(with: "https //youtu.be/abc", in: .text))
        XCTAssertNotNil(DraftValidation.problem(with: "www.youtube.com/watch?v=abc", in: .text))
        XCTAssertEqual(DraftValidation.problem(with: "https://open.spotify.com/track/abc", in: .text), "Spotify links go in the Link tab.")
    }

    func testLinkTab() {
        XCTAssertEqual(DraftValidation.problem(with: "asdfasdf", in: .link), "This is not a link. Song names go in the Text tab.")
        XCTAssertEqual(DraftValidation.problem(with: "https://", in: .link), "This link is incomplete.")
        XCTAssertEqual(DraftValidation.problem(with: "https://youtube", in: .link), "This link is incomplete.")
        XCTAssertTrue(DraftValidation.problem(with: "https://music.apple.com/us/album/x/123", in: .link)?.contains("copy-protected") ?? false)
        XCTAssertTrue(DraftValidation.problem(with: "https://tidal.com/browse/track/1", in: .link)?.contains("copy-protected") ?? false)
        XCTAssertTrue(DraftValidation.problem(with: "https://open.spotify.com/artist/abc", in: .link)?.contains("Only Spotify songs") ?? false)
        XCTAssertTrue(DraftValidation.problem(with: "https://spotify.link/AbCd", in: .link)?.contains("Only Spotify songs") ?? false)
    }

    func testDuplicatesAreFlaggedOnTheLaterLine() {
        let problems = DraftValidation.problems(in: ["XG - LEFT RIGHT", "", "xg - left right ", "a", "KATSEYE - Gabriela"], context: .text)
        XCTAssertEqual(problems, [nil, nil, "Listed twice.", "Too short to search for.", nil])
    }

    func testMixLinks() {
        XCTAssertNil(DraftValidation.problem(withMixLink: "https://www.youtube.com/watch?v=abc&list=RDabc"))
        XCTAssertNil(DraftValidation.problem(withMixLink: "https://soundcloud.com/dj/long-mix"))
        XCTAssertNotNil(DraftValidation.problem(withMixLink: "my favourite mix"))
        XCTAssertTrue(DraftValidation.problem(withMixLink: "https://www.youtube.com/playlist?list=PL1")?.contains("playlist") ?? false)
        XCTAssertTrue(DraftValidation.problem(withMixLink: "https://open.spotify.com/playlist/abc")?.contains("Spotify") ?? false)
        XCTAssertEqual(DraftValidation.problem(withMixLink: "https://"), "This link is incomplete.")
    }

    func testSpaceNeededGrowsWithLength() {
        XCTAssertGreaterThan(DraftValidation.spaceNeeded(forMixOfSeconds: 3600), 450_000_000)
        XCTAssertLessThan(DraftValidation.spaceNeeded(forMixOfSeconds: 3600), 1_000_000_000)
    }

    func testDownloadFailuresReadPlainly() {
        XCTAssertEqual(DownloadFailure.describe("ERROR: [youtube] abc: Private video. Sign in if you've been granted access"), "This video is private.")
        XCTAssertEqual(DownloadFailure.describe("ERROR: unable to download video data: <urlopen error [Errno 8] nodename nor servname provided>"),
                       "No internet connection, or the site could not be reached.")
        XCTAssertEqual(DownloadFailure.describe("WARNING: x\nERROR: [youtube] abc: Sign in to confirm you’re not a bot."),
                       "YouTube wants proof you are not a bot. Wait a while and retry, or update yt-dlp in Settings.")
        XCTAssertEqual(DownloadFailure.describe("ERROR: [youtube] abc: Video unavailable"), "This video is no longer available.")
        XCTAssertEqual(DownloadFailure.describe("ERROR: Unsupported URL: https://example.com"), "This site is not supported.")
        XCTAssertEqual(DownloadFailure.describe("x\nStopped: no output for 180 seconds."), "The download stalled and was stopped. Retry it.")
        XCTAssertEqual(DownloadFailure.describe(""), "Not found.")
        // Unknown errors keep yt-dlp's own words, minus the prefix.
        XCTAssertEqual(DownloadFailure.describe("WARNING: a\nERROR: [generic] xyz: Something odd happened"), "Something odd happened")
        XCTAssertEqual(DownloadFailure.describe("boom"), "boom")
    }
}
