import XCTest
@testable import SetlistCore

final class LinkResolverTests: XCTestCase {
    func testKindOfLink() {
        XCTAssertEqual(LinkResolver.kind(of: "https://open.spotify.com/track/3rUGC1vUpkDG9CZFHMur1t?si=abc"), .spotifyTrack)
        XCTAssertEqual(LinkResolver.kind(of: "https://open.spotify.com/intl-id/track/3rUGC1vUpkDG9CZFHMur1t"), .spotifyTrack)
        XCTAssertEqual(LinkResolver.kind(of: "https://open.spotify.com/playlist/37i9dQZF1DX4JAvHpjipBk"), .spotifyCollection)
        XCTAssertEqual(LinkResolver.kind(of: "https://open.spotify.com/album/1abc"), .spotifyCollection)
        XCTAssertEqual(LinkResolver.kind(of: "https://www.youtube.com/playlist?list=PL123"), .playlist)
        XCTAssertEqual(LinkResolver.kind(of: "https://soundcloud.com/user/sets/my-set"), .playlist)
        XCTAssertEqual(LinkResolver.kind(of: "https://www.youtube.com/watch?v=abc&list=PL123"), .single)
        XCTAssertEqual(LinkResolver.kind(of: "https://youtu.be/abc"), .single)
        XCTAssertEqual(LinkResolver.kind(of: "https://soundcloud.com/user/track"), .single)
        XCTAssertEqual(LinkResolver.kind(of: "XG - LEFT RIGHT"), .notALink)
    }

    func testSpotifyIDAndType() {
        let track = LinkResolver.spotifyEntity("https://open.spotify.com/intl-id/track/3rUGC1vUpkDG9CZFHMur1t?si=x")
        XCTAssertEqual(track?.type, "track")
        XCTAssertEqual(track?.id, "3rUGC1vUpkDG9CZFHMur1t")
        let playlist = LinkResolver.spotifyEntity("https://open.spotify.com/playlist/37i9dQZF1DX4JAvHpjipBk")
        XCTAssertEqual(playlist?.type, "playlist")
        XCTAssertEqual(playlist?.id, "37i9dQZF1DX4JAvHpjipBk")
        XCTAssertNil(LinkResolver.spotifyEntity("https://youtu.be/abc"))
    }

    func testParseSpotifyTrackPage() {
        let html = """
        <html><head>
        <meta property="og:title" content="greedy"/>
        <meta property="og:description" content="Tate McRae · greedy · Song · 2023"/>
        <meta property="og:type" content="music.song"/>
        </head></html>
        """
        XCTAssertEqual(LinkResolver.parseSpotifyTrackPage(html), "Tate McRae - greedy")
        XCTAssertNil(LinkResolver.parseSpotifyTrackPage("<html></html>"))
    }

    func testParseSpotifyTrackPageDecodesEntities() {
        let html = """
        <meta property="og:title" content="Yes or No (Feat. 허윤진, Crush)"/>
        <meta property="og:description" content="GroovyRoom &amp; Crush · Yes or No · Song · 2024"/>
        """
        XCTAssertEqual(LinkResolver.parseSpotifyTrackPage(html), "GroovyRoom & Crush - Yes or No (Feat. 허윤진, Crush)")
    }

    func testParseSpotifyEmbedPage() {
        let json = """
        {"props":{"pageProps":{"state":{"data":{"entity":{"name":"Hot Hits","trackList":[
          {"uri":"spotify:track:1","title":"Party With The Boys","subtitle":"Don Toliver","duration":155492},
          {"uri":"spotify:track:2","title":"greedy","subtitle":"Tate McRae","duration":131872}
        ]}}}}}}
        """
        let html = "<html><body><script id=\"__NEXT_DATA__\" type=\"application/json\">\(json)</script></body></html>"
        XCTAssertEqual(LinkResolver.parseSpotifyEmbedPage(html), ["Don Toliver - Party With The Boys", "Tate McRae - greedy"])
        XCTAssertEqual(LinkResolver.parseSpotifyEmbedPage("<html></html>"), [])
    }

    func testPlaylistArgumentsAndEntryParsing() {
        XCTAssertEqual(LinkResolver.playlistArguments(url: "https://www.youtube.com/playlist?list=PL1"),
                       ["--flat-playlist", "--dump-json", "https://www.youtube.com/playlist?list=PL1"])
        let stdout = """
        {"id":"a","url":"https://www.youtube.com/watch?v=a","title":"A"}
        {"id":"b","webpage_url":"https://soundcloud.com/u/b","title":"B"}
        not json
        """
        XCTAssertEqual(LinkResolver.parsePlaylistEntries(stdout), ["https://www.youtube.com/watch?v=a", "https://soundcloud.com/u/b"])
    }

    func testResolveSingleReturnsURLUnchanged() async throws {
        let resolver = LinkResolver(runner: FakeRunner(), locator: try TestTools.locator(), fetch: { _ in XCTFail("no fetch expected"); return "" })
        let resolved = try await resolver.resolve("https://youtu.be/abc")
        XCTAssertEqual(resolved, ["https://youtu.be/abc"])
    }

    func testResolvePlaylistExpandsViaYtDlp() async throws {
        let runner = FakeRunner(results: [.ok("{\"url\":\"https://www.youtube.com/watch?v=a\"}\n{\"url\":\"https://www.youtube.com/watch?v=b\"}\n")])
        let resolver = LinkResolver(runner: runner, locator: try TestTools.locator(), fetch: { _ in "" })
        let urls = try await resolver.resolve("https://www.youtube.com/playlist?list=PL1")
        XCTAssertEqual(urls, ["https://www.youtube.com/watch?v=a", "https://www.youtube.com/watch?v=b"])
        XCTAssertEqual(runner.calls.first?.arguments, ["--flat-playlist", "--dump-json", "https://www.youtube.com/playlist?list=PL1"])
    }

    func testResolveSpotifyTrackFetchesPage() async throws {
        let fetched = LineCollector()
        let resolver = LinkResolver(runner: FakeRunner(), locator: try TestTools.locator(), fetch: { url in
            fetched.append(url.absoluteString)
            return "<meta property=\"og:title\" content=\"greedy\"/><meta property=\"og:description\" content=\"Tate McRae · greedy · Song · 2023\"/>"
        })
        let resolved = try await resolver.resolve("https://open.spotify.com/intl-id/track/3rUGC1vUpkDG9CZFHMur1t?si=1")
        XCTAssertEqual(resolved, ["Tate McRae - greedy"])
        XCTAssertEqual(fetched.lines, ["https://open.spotify.com/track/3rUGC1vUpkDG9CZFHMur1t"])
    }

    func testResolveSpotifyPlaylistUsesEmbedPage() async throws {
        let fetched = LineCollector()
        let resolver = LinkResolver(runner: FakeRunner(), locator: try TestTools.locator(), fetch: { url in
            fetched.append(url.absoluteString)
            return "<script id=\"__NEXT_DATA__\" type=\"application/json\">{\"props\":{\"pageProps\":{\"state\":{\"data\":{\"entity\":{\"trackList\":[{\"title\":\"T\",\"subtitle\":\"A\"}]}}}}}}</script>"
        })
        let resolved = try await resolver.resolve("https://open.spotify.com/playlist/37i9dQZF1DX4JAvHpjipBk")
        XCTAssertEqual(resolved, ["A - T"])
        XCTAssertEqual(fetched.lines, ["https://open.spotify.com/embed/playlist/37i9dQZF1DX4JAvHpjipBk"])
    }

    func testResolveSpotifyWithoutMetadataThrows() async throws {
        let resolver = LinkResolver(runner: FakeRunner(), locator: try TestTools.locator(), fetch: { _ in "<html></html>" })
        do {
            _ = try await resolver.resolve("https://open.spotify.com/track/abc")
            XCTFail("expected throw")
        } catch let error as LinkResolver.Error {
            XCTAssertEqual(error, .spotifyUnavailable)
        }
    }

    func testResolveNonLinkIsReturnedAsQuery() async throws {
        let resolver = LinkResolver(runner: FakeRunner(), locator: try TestTools.locator(), fetch: { _ in "" })
        let resolved = try await resolver.resolve("XG - LEFT RIGHT")
        XCTAssertEqual(resolved, ["XG - LEFT RIGHT"])
    }

    func testResolveAllKeepsPastedOrderAndReportsFailures() async throws {
        // The first link answers last, so a result ordered by completion would come back reversed.
        let resolver = LinkResolver(runner: FakeRunner(), locator: try TestTools.locator(), fetch: { url in
            let id = url.lastPathComponent
            if id == "bad" { return "<html></html>" }
            try await Task.sleep(for: .milliseconds(id == "slow" ? 300 : 10))
            return "<meta property=\"og:title\" content=\"\(id)\"/><meta property=\"og:description\" content=\"Artist · x\"/>"
        })
        let text = """
        https://open.spotify.com/track/slow

        https://open.spotify.com/track/bad
        https://open.spotify.com/track/fast
        Some - Text
        """
        let (queries, failures) = await resolver.resolveAll(text)
        XCTAssertEqual(queries, ["Artist - slow", "Artist - fast", "Some - Text"])
        XCTAssertEqual(failures.map(\.line), ["https://open.spotify.com/track/bad"])
    }
}
