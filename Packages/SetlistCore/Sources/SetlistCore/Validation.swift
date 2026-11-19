import Foundation

/// Checks on what the user typed or pasted, worded for the person reading them.
public enum DraftValidation {
    public enum Context: Sendable {
        /// The Text tab: song names, with the odd direct link.
        case text
        /// The Link tab: links only.
        case link
    }

    /// Sites whose music is copy-protected, so nothing can be downloaded from their links.
    private static let protectedHosts = [
        "music.apple.com", "itunes.apple.com", "tidal.com", "deezer.com", "music.amazon", "music.youtube.com/library",
    ]

    /// Why this line cannot be downloaded as it stands, or nil when it looks fine.
    public static func problem(with line: String, in context: Context) -> String? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if TrackParser.isURL(text) {
            guard let url = URL(string: text), let host = url.host?.lowercased(), host.contains("."), !host.hasSuffix(".") else {
                return "This link is incomplete."
            }
            if protectedHosts.contains(where: { host.hasSuffix($0) || text.lowercased().contains($0) }) {
                return "Music on \(host) is copy-protected. Type the artist and title in the Text tab instead."
            }
            if host.hasSuffix("spotify.com") || host == "spotify.link" {
                if context == .text { return "Spotify links go in the Link tab." }
                if LinkResolver.spotifyEntity(text) == nil {
                    return "Only Spotify songs, albums and playlists can be read. Open it in Spotify and copy the song's link."
                }
            }
            return nil
        }

        let lower = text.lowercased()
        if lower == "http://" || lower == "https://" {
            return "This link is incomplete."
        }
        if lower.hasPrefix("http") || lower.hasPrefix("www.") {
            return "This looks like a broken link. It should start with https:// and have no spaces."
        }
        if context == .link {
            return "This is not a link. Song names go in the Text tab."
        }
        if text.unicodeScalars.filter({ CharacterSet.alphanumerics.contains($0) }).count < 2 {
            return "Too short to search for."
        }
        return nil
    }

    /// For each line: its problem, or "Listed twice." when an earlier line says the same thing. nil is fine.
    public static func problems(in lines: [String], context: Context) -> [String?] {
        var seen = Set<String>()
        return lines.map { line in
            let key = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return nil }
            if let problem = problem(with: line, in: context) { return problem }
            return seen.insert(key).inserted ? nil : "Listed twice."
        }
    }

    /// Why this link cannot be identified as a mix, or nil when it can be tried.
    public static func problem(withMixLink text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = problem(with: trimmed, in: .link) {
            return TrackParser.isURL(trimmed) || trimmed.lowercased().hasPrefix("http") ? problem
                : "Paste the link of a mix first. It should start with https://."
        }
        guard TrackParser.isURL(trimmed) else { return "Paste the link of a mix first. It should start with https://." }
        switch LinkResolver.kind(of: trimmed) {
        case .playlist:
            return "This is a playlist, not one mix. Paste it in the Link tab to download its videos."
        case .spotifyTrack, .spotifyCollection:
            return "Spotify has no audio to listen to. Paste Spotify links in the Link tab."
        default:
            return nil
        }
    }

    /// Bytes the mono 44.1 kHz WAV of a mix takes, with headroom for the download before conversion.
    public static func spaceNeeded(forMixOfSeconds seconds: Double) -> Int64 {
        Int64(seconds * 44_100 * 2 * 1.5) + 200_000_000
    }
}

/// Turns yt-dlp's error output into one plain sentence.
public enum DownloadFailure {
    private static let known: [(pattern: String, message: String)] = [
        (#"getaddrinfo|nodename nor servname|name resolution|Network is unreachable|No route to host|Connection refused|timed out|Unable to connect|network connection was lost|Could not resolve"#,
         "No internet connection, or the site could not be reached."),
        (#"No space left on device"#, "The disk is full."),
        (#"confirm you.?re not a bot"#, "YouTube wants proof you are not a bot. Wait a while and retry, or update yt-dlp in Settings."),
        (#"confirm your age|age.restricted"#, "This video is age-restricted and needs a signed-in account."),
        (#"[Pp]rivate video|video is private"#, "This video is private."),
        (#"members.only|Join this channel"#, "This video is for channel members only."),
        (#"not available in your country|geo.?restrict|blocked it in your country"#, "This is not available in your country."),
        (#"Video unavailable|has been removed|no longer available|account.*terminated|does not exist"#, "This video is no longer available."),
        (#"HTTP Error 429|Too Many Requests"#, "The site is limiting requests. Wait a few minutes and retry."),
        (#"HTTP Error 403"#, "The site refused the download. Updating yt-dlp in Settings usually fixes this."),
        (#"DRM"#, "This is copy-protected and cannot be downloaded."),
        (#"Unsupported URL"#, "This site is not supported."),
        (#"is a live event|live stream|This live event"#, "This is a live stream. Wait until it has ended."),
        (#"Stopped: no output for"#, "The download stalled and was stopped. Retry it."),
    ]

    /// A plain sentence for a known failure; otherwise yt-dlp's own last error line, without its prefix.
    public static func describe(_ stderr: String) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Not found." }
        for (pattern, message) in known where text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return message
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let last = lines.last(where: { $0.hasPrefix("ERROR:") }) ?? lines.last ?? text
        return last.replacingOccurrences(of: #"^ERROR:\s*(\[[^\]]+\]\s*[^:]*:\s*)?"#, with: "", options: .regularExpression)
    }
}
