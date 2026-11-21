import XCTest
@testable import SetlistCore

final class CandidateRankerTests: XCTestCase {
    private func c(_ title: String, by uploader: String = "", _ duration: Double? = 180, url: String? = nil) -> SearchCandidate {
        SearchCandidate(url: url ?? "https://x/\(title)", title: title, uploader: uploader, duration: duration)
    }

    private func best(_ query: String, _ candidates: [SearchCandidate]) -> String? {
        CandidateRanker.ranked(candidates, for: query).first?.title
    }

    func testNamedRemixBeatsTheOriginalAndOtherRemixes() {
        let found = [
            c("NewJeans (뉴진스) 'Right Now' Official MV", by: "HYBE LABELS"),
            c("뉴진스(NewJeans) - Right Now (R&B Cover)", by: "GrandpaFM"),
            c("NewJeans - Right now (KyoU Remix)", by: "KyoU"),
            c("NewJeans - right now (R&B remix)", by: "bii"),
        ]
        XCTAssertEqual(best("NewJeans - Right Now (R&B Remix)", found), "NewJeans - right now (R&B remix)")
        XCTAssertEqual(best("NewJeans - Right Now (KyoU Remix)", found), "NewJeans - Right now (KyoU Remix)")
    }

    func testPlainLineAvoidsVersionsNobodyAskedFor() {
        let found = [
            c("XG - LEFT RIGHT (Sped Up)", by: "speedy"),
            c("XG - LEFT RIGHT (Jersey Club Remix)", by: "dj"),
            c("XG - LEFT RIGHT reaction", by: "reactor"),
            c("XG - LEFT RIGHT (Official Music Video)", by: "XG"),
            c("XG - LEFT RIGHT (Live)", by: "XG"),
        ]
        XCTAssertEqual(best("XG - LEFT RIGHT", found), "XG - LEFT RIGHT (Official Music Video)")
    }

    func testEqualScoresKeepTheSearchOrder() {
        let found = [c("A - B", url: "https://youtube/1"), c("A - B", url: "https://soundcloud/1")]
        XCTAssertEqual(CandidateRanker.ranked(found, for: "A - B").map(\.url), ["https://youtube/1", "https://soundcloud/1"])
    }

    func testLaterResultWinsOnlyWhenItMatchesBetter() {
        let found = [c("Artist - Song (Live at Wembley)"), c("Artist - Song")]
        XCTAssertEqual(best("Artist - Song", found), "Artist - Song")
        XCTAssertEqual(best("Artist - Song (Live)", found), "Artist - Song (Live at Wembley)")
    }

    func testOriginalMixCountsAsTheOriginal() {
        let found = [c("Artist - Song (Someone Remix)"), c("Artist - Song (Original Mix)")]
        XCTAssertEqual(best("Artist - Song", found), "Artist - Song (Original Mix)")
    }

    func testWholeMixesAndSnippetsLoseToASongLengthUpload() {
        let found = [c("Artist - Song (Club Edit)", 3600), c("Artist - Song (Club Edit)", 20), c("Artist - Song (Club Edit)", 200, url: "https://x/right")]
        XCTAssertEqual(CandidateRanker.ranked(found, for: "Artist - Song (Club Edit)").first?.url, "https://x/right")
    }

    func testWrongArtistLoses() {
        let found = [c("Akon - Right Now (Na Na Na)", by: "Akon"), c("Right Now", by: "NewJeans")]
        XCTAssertEqual(best("NewJeans - Right Now", found), "Right Now")
    }

    func testStyledLettersAndSpacingStillMatch() {
        let found = [c("Other - Tune"), c("𝙉𝙚𝙬 𝙅𝙚𝙖𝙣𝙨 - 𝙍𝙞𝙜𝙝𝙩 𝙉𝙤𝙬")]
        XCTAssertEqual(best("NewJeans - Right Now", found), "𝙉𝙚𝙬 𝙅𝙚𝙖𝙣𝙨 - 𝙍𝙞𝙜𝙝𝙩 𝙉𝙤𝙬")
    }

    func testParsesYtDlpSearchOutput() {
        let output = """
        {"title": "A - B (Remix)", "uploader": "up", "duration": 174, "url": "https://www.youtube.com/watch?v=1", "webpage_url": "https://www.youtube.com/watch?v=1"}
        not json
        {"title": "A - B", "channel": "chan", "duration": 173.3, "url": "https://api.soundcloud.com/tracks/1", "webpage_url": "https://soundcloud.com/u/a-b"}
        {"title": "no address"}
        {"title": "url only", "url": "https://youtu.be/2"}
        """
        XCTAssertEqual(CandidateRanker.parse(searchOutput: output), [
            SearchCandidate(url: "https://www.youtube.com/watch?v=1", title: "A - B (Remix)", uploader: "up", duration: 174),
            SearchCandidate(url: "https://soundcloud.com/u/a-b", title: "A - B", uploader: "chan", duration: 173.3),
            SearchCandidate(url: "https://youtu.be/2", title: "url only", uploader: "", duration: nil),
        ])
    }
}
