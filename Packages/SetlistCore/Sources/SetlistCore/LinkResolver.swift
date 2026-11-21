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

/// One song a pasted link stands for.
public struct LinkEntry: Equatable, Sendable {
    /// What to download: a page address, or "Artist - Title" to search for.
    public var query: String
    /// The song as "Artist - Title", when the link is an address and its page was read.
    public var name: String?

    public init(query: String, name: String? = nil) {
        self.query = query
        self.name = name
    }
}

/// What a pasted link turned out to contain.
public struct ResolvedLink: Equatable, Sendable {
    public var entries: [LinkEntry]
    /// The playlist's own name, for naming the folder.
    public var title: String?

    public init(entries: [LinkEntry], title: String? = nil) {
        self.entries = entries
        self.title = title
    }
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
        parsePlaylist(stdout).entries.map(\.url)
    }

    /// A playlist entry as the quick listing gives it. SoundCloud leaves out the title, and for all but
    /// the first few songs gives an address made of the song's number.
    public struct PlaylistEntry: Equatable, Sendable {
        public var id: String?
        public var url: String
        public var title: String?
        public var uploader: String?
    }

    public static func parsePlaylist(_ stdout: String) -> (title: String?, entries: [PlaylistEntry]) {
        var title: String?
        let entries: [PlaylistEntry] = stdout.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = (obj["url"] as? String) ?? (obj["webpage_url"] as? String) else { return nil }
            if title == nil { title = text(obj["playlist_title"]) }
            return PlaylistEntry(id: text(obj["id"]), url: url, title: text(obj["title"]),
                                 uploader: text(obj["uploader"]) ?? text(obj["channel"]))
        }
        return (title, entries)
    }

    private static func text(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }

    // MARK: Song names

    /// How many songs of a playlist one yt-dlp run reads the names of. Longer playlists are split over
    /// up to `nameRuns` runs at the same time, since each song costs about a second.
    static let namesPerRun = 10
    static let nameRuns = 4

    /// The 1-based stretches of a playlist of `count` songs that are read at the same time.
    public static func nameRanges(count: Int) -> [ClosedRange<Int>] {
        guard count > 0 else { return [] }
        let runs = min(nameRuns, max(1, count / namesPerRun))
        let size = Int((Double(count) / Double(runs)).rounded(.up))
        return stride(from: 1, through: count, by: size).map { $0...min(count, $0 + size - 1) }
    }

    /// Reads title, uploader and page address without downloading: of the songs `range` of a playlist,
    /// or of the one song at `url` when there is no range.
    public static func nameArguments(url: String, range: ClosedRange<Int>? = nil) -> [String] {
        ["--skip-download", "--no-warnings", "--ignore-errors", "--socket-timeout", "30"]
            + (range.map { ["-I", "\($0.lowerBound):\($0.upperBound)"] } ?? ["--no-playlist"])
            + ["--print", "%(.{id,webpage_url,uploader,title})j", url]
    }

    /// True for a link whose own title often leaves the artist out, so its page is worth reading for the name.
    public static func needsNameLookup(_ url: String) -> Bool {
        URL(string: url)?.host?.lowercased().contains("soundcloud.com") == true
    }

    /// The song at `url` as "Artist - Title", read from its page. nil when the page could not be read.
    public func songName(at url: String) async -> String? {
        guard let ytDlp = try? locator.url(for: .ytDlp),
              let result = try? await runner.run(ytDlp, arguments: Self.nameArguments(url: url), onLine: nil),
              let entry = Self.parsePlaylist(result.stdout).entries.first else { return nil }
        return Self.songName(title: entry.title, uploader: entry.uploader, url: entry.url)
    }

    /// Things uploaders add to a title that are not part of the song's name.
    private static let promotion = try! NSRegularExpression(
        pattern: #"\s*\|\s*#.*$|[\(\[]?\s*\bfree\s+(download|dl)\b\s*[\)\]]?"#, options: .caseInsensitive)
    private static let unavailable: Set<String> = ["[Private video]", "[Deleted video]", "[Private track]"]

    /// The song as "Artist - Title" from what its page says. A title that already names the artist is
    /// used as it is; a SoundCloud title that does not gets the uploader in front, who on SoundCloud is
    /// the artist or the person who made the edit. nil when there is nothing usable.
    public static func songName(title: String?, uploader: String?, url: String) -> String? {
        guard let title, !unavailable.contains(title) else { return nil }
        var name = promotion.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: " ")
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—|"))
        guard !name.isEmpty else { return nil }
        if FileNameFormat.split(name).artist != nil { return name }
        guard URL(string: url)?.host?.lowercased().contains("soundcloud.com") == true,
              let uploader = text(uploader) else { return name }
        return "\(uploader) - \(name)"
    }

    /// Titles and page addresses of a playlist's songs by id, read in a few runs at the same time.
    /// Songs that cannot be read (private, removed) are simply missing.
    /// `onFound` is called with everything read so far each time one more song comes in.
    private func names(of url: String, count: Int, ytDlp: URL,
                       onFound: (@Sendable ([String: PlaylistEntry]) -> Void)?) async -> [String: PlaylistEntry] {
        let found = Found()
        await withTaskGroup(of: Void.self) { group in
            for range in Self.nameRanges(count: count) {
                group.addTask {
                    _ = try? await runner.run(ytDlp, arguments: Self.nameArguments(url: url, range: range)) { line in
                        guard let entry = Self.parsePlaylist(line).entries.first, let id = entry.id else { return }
                        onFound?(found.add(entry, id: id))
                    }
                }
            }
        }
        return found.all
    }

    /// Songs read so far, filled from several runs at once.
    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: PlaylistEntry] = [:]

        var all: [String: PlaylistEntry] { lock.withLock { entries } }

        func add(_ entry: PlaylistEntry, id: String) -> [String: PlaylistEntry] {
            lock.withLock {
                entries[id] = entry
                return entries
            }
        }
    }

    // MARK: Resolution

    /// Download queries for one pasted line.
    public func resolve(_ text: String) async throws -> [String] {
        try await lookUp(text).entries.map(\.query)
    }

    /// The songs one pasted line stands for, with their names where the link's page gives them.
    /// For a playlist whose names have to be read song by song, `onUpdate` gets the list as soon as it is
    /// known and again each time a name comes in, so the songs can be shown while the rest is read.
    public func lookUp(_ text: String, onUpdate: (@Sendable (ResolvedLink) -> Void)? = nil) async throws -> ResolvedLink {
        let s = text.trimmingCharacters(in: .whitespaces)
        switch Self.kind(of: s) {
        case .notALink, .single:
            return ResolvedLink(entries: [LinkEntry(query: s)])
        case .playlist:
            let ytDlp = try locator.url(for: .ytDlp)
            let result = try await runner.run(ytDlp, arguments: Self.playlistArguments(url: s), onLine: nil)
            guard result.exitCode == 0 else {
                throw ToolError.failed(.ytDlp, exitCode: result.exitCode, stderr: result.stderr)
            }
            let (title, listed) = Self.parsePlaylist(result.stdout)
            guard !listed.isEmpty else { throw Error.playlistEmpty(s) }
            // YouTube lists titles straight away. SoundCloud does not, so its songs are read one by one.
            let resolved: @Sendable ([String: PlaylistEntry]) -> ResolvedLink = { read in
                ResolvedLink(entries: listed.map { entry in
                    let known = entry.id.flatMap { read[$0] } ?? entry
                    return LinkEntry(query: known.url, name: Self.songName(title: known.title, uploader: known.uploader, url: known.url))
                }, title: title)
            }
            guard listed.contains(where: { $0.title == nil }) else { return resolved([:]) }
            onUpdate?(resolved([:]))
            return resolved(await names(of: s, count: listed.count, ytDlp: ytDlp) { onUpdate?(resolved($0)) })
        case .spotifyTrack:
            guard let entity = Self.spotifyEntity(s) else { return ResolvedLink(entries: [LinkEntry(query: s)]) }
            let page = try await fetch(URL(string: "https://open.spotify.com/track/\(entity.id)")!)
            guard let query = Self.parseSpotifyTrackPage(page) else { throw Error.spotifyUnavailable }
            return ResolvedLink(entries: [LinkEntry(query: query)])
        case .spotifyCollection:
            guard let entity = Self.spotifyEntity(s) else { return ResolvedLink(entries: [LinkEntry(query: s)]) }
            let page = try await fetch(URL(string: "https://open.spotify.com/embed/\(entity.type)/\(entity.id)")!)
            let queries = Self.parseSpotifyEmbedPage(page)
            guard !queries.isEmpty else { throw Error.spotifyUnavailable }
            return ResolvedLink(entries: queries.map { LinkEntry(query: $0) })
        }
    }

    /// Resolves every non-empty line, `concurrency` at a time, keeping the pasted order.
    /// Lines that fail resolution are reported, not fatal.
    public func resolveAll(_ text: String, concurrency: Int = 4) async -> (queries: [String], failures: [(line: String, error: String)]) {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var results = [Result<[String], Swift.Error>?](repeating: nil, count: lines.count)
        await withTaskGroup(of: (Int, Result<[String], Swift.Error>).self) { group in
            var next = 0
            func launch() {
                let i = next
                next += 1
                group.addTask {
                    do { return (i, .success(try await resolve(lines[i]))) } catch { return (i, .failure(error)) }
                }
            }
            while next < min(max(1, concurrency), lines.count) { launch() }
            for await (i, result) in group {
                results[i] = result
                if next < lines.count { launch() }
            }
        }

        var queries: [String] = []
        var failures: [(String, String)] = []
        for (line, result) in zip(lines, results) {
            switch result {
            case let .success(resolved)?: queries += resolved
            case let .failure(error)?: failures.append((line, error.localizedDescription))
            case nil: break
            }
        }
        return (queries, failures)
    }
}
