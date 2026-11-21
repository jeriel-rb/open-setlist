import Foundation

/// One search result that could be the song a line asks for.
public struct SearchCandidate: Equatable, Sendable {
    /// The page to download from.
    public let url: String
    public let title: String
    public let uploader: String
    /// Length in seconds, when the site reports it.
    public let duration: Double?

    public init(url: String, title: String, uploader: String, duration: Double?) {
        self.url = url
        self.title = title
        self.uploader = uploader
        self.duration = duration
    }
}

/// Picks, among search results, the upload whose title says what the line says: the same song in the
/// same version. A remix named in the line has to be in the title; a remix, cover or live take the
/// line did not ask for counts against a result.
public enum CandidateRanker {
    /// Words that say an upload is some particular version of a song.
    static let versionWords: Set<String> = [
        "remix", "mix", "edit", "flip", "bootleg", "mashup", "rework", "vip", "dub", "cover", "live", "acoustic",
        "instrumental", "karaoke", "nightcore", "sped", "slowed", "reverb", "8d", "extended", "radio", "club",
        "version", "remaster", "remastered", "demo", "medley",
    ]
    /// Version words that leave the recording close to the original, so they cost less when unasked for.
    static let mildVersionWords: Set<String> = ["version", "remaster", "remastered", "extended", "radio"]
    /// Words of uploads that are about a song but are not the song.
    static let notTheSongWords: Set<String> = [
        "reaction", "tutorial", "lesson", "choreography", "practice", "fancam", "teaser", "trailer", "review", "compilation",
    ]
    /// Words in a line that a matching title often leaves out.
    static let fillerWords: Set<String> = ["feat", "ft", "featuring", "prod", "official", "audio", "video", "the", "and"]

    /// Longer than this is a whole mix or album, shorter than `shortestSong` a snippet.
    static let longestSong: Double = 900
    static let shortestSong: Double = 45

    /// Lowercased words with styled letters and accents flattened ("𝙉𝙤𝙬" and "Nów" both give "now").
    static func words(_ text: String) -> [String] {
        text.precomposedStringWithCompatibilityMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "original mix", with: " ")
            .split { !$0.isLetter && !$0.isNumber }
            .map { $0 == "ver" ? "version" : String($0) }
    }

    /// Higher is a better match. Only the order of scores for one query means anything.
    public static func score(_ candidate: SearchCandidate, for query: String) -> Double {
        let wanted = words(query).filter { !fillerWords.contains($0) }
        guard !wanted.isEmpty else { return 0 }
        let titleWords = Set(words(candidate.title))
        let allWords = titleWords.union(words(candidate.uploader))
        // "NewJeans" in the line should find "New Jeans" in a title.
        let squashed = words(candidate.title + " " + candidate.uploader).joined()
        func has(_ word: String) -> Bool { allWords.contains(word) || (word.count >= 4 && squashed.contains(word)) }

        var score = 10 * Double(wanted.filter(has).count) / Double(wanted.count)

        let wantedSet = Set(wanted)
        for word in wantedSet.intersection(versionWords) where !titleWords.contains(word) { score -= 4 }
        for word in titleWords.intersection(versionWords).subtracting(wantedSet) {
            score -= mildVersionWords.contains(word) ? 1 : 3
        }
        if !titleWords.intersection(notTheSongWords).subtracting(wantedSet).isEmpty { score -= 4 }

        // "Artist - Title": a result that mentions none of the artist's words is someone else's song.
        if let dash = query.range(of: " - ") {
            let artist = words(String(query[..<dash.lowerBound])).filter { !fillerWords.contains($0) }
            if !artist.isEmpty, !artist.contains(where: has) { score -= 3 }
        }

        if let duration = candidate.duration {
            if duration > longestSong { score -= 5 }
            if duration < shortestSong { score -= 3 }
        }
        return score
    }

    /// Best match first. Equal scores keep the order the results came in.
    public static func ranked(_ candidates: [SearchCandidate], for query: String) -> [SearchCandidate] {
        candidates.enumerated()
            .map { (offset: $0.offset, candidate: $0.element, score: score($0.element, for: query)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map(\.candidate)
    }

    /// Results from `yt-dlp --flat-playlist --dump-json` on a search: one JSON object per line.
    public static func parse(searchOutput: String) -> [SearchCandidate] {
        struct Entry: Decodable {
            let title: String?
            let uploader: String?
            let channel: String?
            let duration: Double?
            let url: String?
            let webpage_url: String?
        }
        let decoder = JSONDecoder()
        return searchOutput.split(separator: "\n").compactMap { line in
            guard let entry = try? decoder.decode(Entry.self, from: Data(line.utf8)),
                  let url = entry.webpage_url ?? entry.url, let title = entry.title else { return nil }
            return SearchCandidate(url: url, title: title, uploader: entry.uploader ?? entry.channel ?? "", duration: entry.duration)
        }
    }
}
