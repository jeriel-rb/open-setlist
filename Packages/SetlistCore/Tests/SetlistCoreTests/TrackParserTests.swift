import XCTest
@testable import SetlistCore

final class TrackParserTests: XCTestCase {
    static let example = """
    💿 Track List
    00:00 NewJeans - Right Now (R&B Remix by Marukaobeats)
    01:30 XG - LEFT RIGHT
    03:50 LE SSERAFIM - CRAZY (R&B Flip by Childish Wave)
    05:17 NewJeans - ETA (R&B Remix by Marukaobeats)
    07:35 GroovyRoom - Yes or No (Feat. 허윤진, Crush) (R&B Remix by Childish Wave)
    09:12 IVE - Accendio (moonlight remix by jis jeong)
    10:37 NewJeans - Cool With You (In The Mood Remix by Marukaobeats)
    12:40 KATSEYE - Gabriela
    14:13 aespa - Thirsty
    15:30 FIFTY FIFTY - Gravity
    17:32 KiiiKiii - DANCING ALONE (Chill R&B Remix by Marukaobeats)
    19:37 BTS - SWIM with RM (Chill Hip Hop Remix)
    21:38 CORTIS - Wassup
    23:15 LE SSERAFIM - Impurities
    24:38 KISS OF LIFE - Sugarcoat (NATTY Solo)
    26:30 KISS OF LIFE - Shhh
    28:53 NewJeans - Attention (250 Remix)
    30:12 Jung Kook - Standing Next to You
    32:09 LOOΠΔ / ODD EYE CIRCLE - Sweet Crazy Love
    33:36 ILLIT - Lucky Girl Syndrome (R&B Remix by Childish Wave)
    35:02 TOMORROW X TOGETHER - Over The Moon (R&B Remix)
    36:22 Hearts2Hearts - The Chase (R&B Remix by dijei 디제이)
    """

    func testStripsTimestampAndKeepsQuery() {
        let line = TrackParser.clean("00:00 NewJeans - Right Now")
        XCTAssertEqual(line, ParsedLine(start: 0, query: "NewJeans - Right Now"))
        let later = TrackParser.clean("[12:40] - KATSEYE - Gabriela")
        XCTAssertEqual(later, ParsedLine(start: 760, query: "KATSEYE - Gabriela"))
    }

    func testStripsNumbering() {
        XCTAssertEqual(TrackParser.clean("1. XG - LEFT RIGHT")?.query, "XG - LEFT RIGHT")
        XCTAssertEqual(TrackParser.clean("12) XG - LEFT RIGHT")?.query, "XG - LEFT RIGHT")
        XCTAssertEqual(TrackParser.clean("- XG - LEFT RIGHT")?.query, "XG - LEFT RIGHT")
        XCTAssertNil(TrackParser.clean("1. XG - LEFT RIGHT")?.start)
    }

    func testDropsHeaderLines() {
        XCTAssertNil(TrackParser.clean("💿 Track List"))
        XCTAssertNil(TrackParser.clean("Tracklist:"))
        XCTAssertNil(TrackParser.clean("   "))
        // A long line that merely contains the word is a real track, keep it.
        XCTAssertNotNil(TrackParser.clean("Some Artist - Playlist Of My Life (Extended Club Mix Edition)"))
    }

    func testKeepsShortSongsThatContainHeaderWords() {
        XCTAssertEqual(TrackParser.clean("03:10 XG - Playlist")?.query, "XG - Playlist")
        XCTAssertEqual(TrackParser.clean("Artist - Setlist")?.query, "Artist - Setlist")
    }

    func testThreeDigitMinutes() {
        XCTAssertEqual(TrackParser.clean("120:30 A - B"), ParsedLine(start: 7230, query: "A - B"))
    }

    func testKeepsURLs() {
        let url = "https://www.youtube.com/watch?v=abc123&list=PL1"
        XCTAssertEqual(TrackParser.clean("3. \(url)")?.query, url)
    }

    func testIsURL() {
        XCTAssertTrue(TrackParser.isURL("https://youtu.be/abc123"))
        XCTAssertTrue(TrackParser.isURL("https://www.youtube.com/shorts/abc123"))
        XCTAssertTrue(TrackParser.isURL("https://www.youtube.com/watch?v=abc&list=PL1"))
        XCTAssertTrue(TrackParser.isURL("http://soundcloud.com/user/track"))
        XCTAssertFalse(TrackParser.isURL("XG - LEFT RIGHT"))
        XCTAssertFalse(TrackParser.isURL("https:// not a url"))
    }

    func testDedupesCaseInsensitive() {
        let text = "XG - LEFT RIGHT\nxg - left right\nKATSEYE - Gabriela"
        XCTAssertEqual(TrackParser.parse(text), ["XG - LEFT RIGHT", "KATSEYE - Gabriela"])
    }

    func testWindowsLineEndingsAndEmojiHeader() {
        let windows = Self.example.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n"
        let queries = TrackParser.parse(windows)
        XCTAssertEqual(queries.count, 22)
        XCTAssertEqual(queries.first, "NewJeans - Right Now (R&B Remix by Marukaobeats)")
        XCTAssertEqual(queries.last, "Hearts2Hearts - The Chase (R&B Remix by dijei 디제이)")
        XCTAssertEqual(queries, TrackParser.parse(Self.example))
    }

    func testParseTimestampHours() {
        XCTAssertEqual(TrackParser.parseTimestamp("1:02:03"), 3723)
        XCTAssertEqual(TrackParser.parseTimestamp("01:30"), 90)
        XCTAssertEqual(TrackParser.parseTimestamp("0:00"), 0)
        XCTAssertNil(TrackParser.parseTimestamp("1:2"))
        XCTAssertNil(TrackParser.parseTimestamp("abc"))
    }

    func testFindTracklistNeedsThree() {
        XCTAssertNil(TrackParser.findTracklist(in: "00:00 A - B\n01:00 C - D\nchatter"))
        let found = TrackParser.findTracklist(in: "intro text\n00:00 A - B\n01:00 C - D\n02:30 E - F\nthanks for watching")
        XCTAssertEqual(found, [
            ParsedLine(start: 0, query: "A - B"),
            ParsedLine(start: 60, query: "C - D"),
            ParsedLine(start: 150, query: "E - F"),
        ])
    }

    func testSingleDigitMinutesAndTrailingSpaces() {
        let text = """
        0:00 BLANKPINK - GO (House Remix by dijei)
        1:45 JENNIE & Dua Lipa - Handlebars (House Remix by Swiiim)
        5:50 Daft Punk - One More Time (Scarmixxed 'Baby' Edit) 
        24:53 LE SSERAFIM - Eve, Psyche & The Bluebeard's wife (BRLLNT Edit)
        41:38 Girls' Generation - Gee (Remix by Onion)
        """
        let queries = TrackParser.parse(text)
        XCTAssertEqual(queries, [
            "BLANKPINK - GO (House Remix by dijei)",
            "JENNIE & Dua Lipa - Handlebars (House Remix by Swiiim)",
            "Daft Punk - One More Time (Scarmixxed 'Baby' Edit)",
            "LE SSERAFIM - Eve, Psyche & The Bluebeard's wife (BRLLNT Edit)",
            "Girls' Generation - Gee (Remix by Onion)",
        ])
        XCTAssertEqual(TrackParser.findTracklist(in: text)?.map(\.start), [0, 105, 350, 1493, 2498])
    }

    func testFindTracklistOnExample() {
        let found = TrackParser.findTracklist(in: Self.example)
        XCTAssertEqual(found?.count, 22)
        XCTAssertEqual(found?[1], ParsedLine(start: 90, query: "XG - LEFT RIGHT"))
    }
}
