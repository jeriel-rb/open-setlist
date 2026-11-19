import Foundation

public enum LinkKind: Equatable, Sendable {
    /// open.spotify.com/track/… — resolved to "Artist - Title" (Spotify serves no audio).
    case spotifyTrack
    /// open.spotify.com/album|playlist/… — expanded to "Artist - Title" per track.
    case spotifyCollection
    /// YouTube `playlist?list=` or SoundCloud `/sets/` — expanded to entry URLs.
    case playlist
    /// Any other URL yt-dlp can download directly.
    case single
    case notALink
}

/// Turns pasted links into download queries: URLs for yt-dlp, or "Artist - Title" text for Spotify.
public struct LinkResolver: Sendable {
    public enum Error: Swift.Error, Equatable, LocalizedError {
        case spotifyUnavailable
        case playlistEmpty(String)

        public var errorDescription: String? {
            switch self {
            case .spotifyUnavailable: "Could not read the song details from Spotify. Paste the artist and title as text instead."
            case let .playlistEmpty(url): "No tracks found in \(url)."
            }
        }
    }

    public typealias Fetch = @Sendable (URL) async throws -> String

    public let runner: CommandRunning
    public let locator: ToolLocator
    private let fetch: Fetch

    public init(runner: CommandRunning, locator: ToolLocator, fetch: Fetch? = nil) {
        self.runner = runner
        self.locator = locator
        self.fetch = fetch ?? Self.defaultFetch
    }

    private static let defaultFetch: Fetch = { url in
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) Setlist", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Classification

    public static func kind(of text: String) -> LinkKind {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard TrackParser.isURL(s), let url = URL(string: s), let host = url.host?.lowercased() else { return .notALink }
        if host.hasSuffix("spotify.com") {
            switch spotifyEntity(s)?.type {
            case "track": return .spotifyTrack
            case "album", "playlist": return .spotifyCollection
            default: return .single
            }
        }
        if host.contains("youtube.com"), url.path.hasPrefix("/playlist") { return .playlist }
        if host.contains("soundcloud.com"), url.path.contains("/sets/") { return .playlist }
        return .single
    }

    private static let spotifyPath = try! NSRegularExpression(pattern: #"/(track|album|playlist)/([A-Za-z0-9]+)"#)

    /// ("track", id) for any open.spotify.com URL shape, including `/intl-xx/` prefixes.
    public static func spotifyEntity(_ text: String) -> (type: String, id: String)? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              url.host?.lowercased().hasSuffix("spotify.com") == true else { return nil }
        let path = url.path
        guard let m = spotifyPath.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let t = Range(m.range(at: 1), in: path), let i = Range(m.range(at: 2), in: path) else { return nil }
        return (String(path[t]), String(path[i]))
    }

    // MARK: Spotify pages

    private static func meta(_ property: String, in html: String) -> String? {
        let pattern = #"<meta\s+property="\#(NSRegularExpression.escapedPattern(for: property))"\s+content="([^"]*)""#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range(at: 1), in: html) else { return nil }
        return decodeEntities(String(html[r]))
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    /// `og:title` is the song, `og:description` starts with the artist: "Artist · Song · Song · 2023".
    public static func parseSpotifyTrackPage(_ html: String) -> String? {
        guard let title = meta("og:title", in: html), !title.isEmpty,
              let description = meta("og:description", in: html),
              let artist = description.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespaces),
              !artist.isEmpty else { return nil }
        return "\(artist) - \(title)"
    }

    /// The embed page ships a `__NEXT_DATA__` JSON blob whose entity has `trackList[{title, subtitle}]`.
    public static func parseSpotifyEmbedPage(_ html: String) -> [String] {
        guard let start = html.range(of: "<script id=\"__NEXT_DATA__\" type=\"application/json\">"),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let data = String(html[start.upperBound..<end.lowerBound]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        guard let list = firstValue(forKey: "trackList", in: json) as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let title = item["title"] as? String, let artist = item["subtitle"] as? String else { return nil }
            return "\(artist) - \(title)"
        }
    }

    private static func firstValue(forKey key: String, in object: Any) -> Any? {
        if let dict = object as? [String: Any] {
            if let v = dict[key] { return v }
            for v in dict.values { if let found = firstValue(forKey: key, in: v) { return found } }
        } else if let array = object as? [Any] {
            for v in array { if let found = firstValue(forKey: key, in: v) { return found } }
        }
        return nil
    }

    // MARK: Playlists

    public static func playlistArguments(url: String) -> [String] {
        ["--flat-playlist", "--dump-json", url]
    }

    /// One JSON object per line; prefers `url`, falls back to `webpage_url`.
    public static func parsePlaylistEntries(_ stdout: String) -> [String] {
        stdout.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (obj["url"] as? String) ?? (obj["webpage_url"] as? String)
        }
    }

    // MARK: Resolution

    /// Download queries for one pasted line.
    public func resolve(_ text: String) async throws -> [String] {
        let s = text.trimmingCharacters(in: .whitespaces)
        switch Self.kind(of: s) {
        case .notALink, .single:
            return [s]
        case .playlist:
            let ytDlp = try locator.url(for: .ytDlp)
            let result = try await runner.run(ytDlp, arguments: Self.playlistArguments(url: s), onLine: nil)
            guard result.exitCode == 0 else {
                throw ToolError.failed(.ytDlp, exitCode: result.exitCode, stderr: result.stderr)
            }
            let entries = Self.parsePlaylistEntries(result.stdout)
            guard !entries.isEmpty else { throw Error.playlistEmpty(s) }
            return entries
        case .spotifyTrack:
            guard let entity = Self.spotifyEntity(s) else { return [s] }
            let page = try await fetch(URL(string: "https://open.spotify.com/track/\(entity.id)")!)
            guard let query = Self.parseSpotifyTrackPage(page) else { throw Error.spotifyUnavailable }
            return [query]
        case .spotifyCollection:
            guard let entity = Self.spotifyEntity(s) else { return [s] }
            let page = try await fetch(URL(string: "https://open.spotify.com/embed/\(entity.type)/\(entity.id)")!)
            let queries = Self.parseSpotifyEmbedPage(page)
            guard !queries.isEmpty else { throw Error.spotifyUnavailable }
            return queries
        }
    }

    /// Resolves every non-empty line, in order. Lines that fail resolution are reported, not fatal.
    public func resolveAll(_ text: String) async -> (queries: [String], failures: [(line: String, error: String)]) {
        var queries: [String] = []
        var failures: [(String, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            do {
                queries += try await resolve(line)
            } catch {
                failures.append((line, error.localizedDescription))
            }
        }
        return (queries, failures)
    }
}
