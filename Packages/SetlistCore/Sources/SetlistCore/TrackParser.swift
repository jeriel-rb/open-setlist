import Foundation

/// One cleaned line of a pasted tracklist.
public struct ParsedLine: Equatable, Sendable {
    public let start: Double?
    public let query: String

    public init(start: Double?, query: String) {
        self.start = start
        self.query = query
    }
}

/// Turns pasted text (YouTube descriptions, comments, hand-typed lists) into track queries.
public enum TrackParser {
    private static let timestamp = try! NSRegularExpression(
        pattern: #"^\s*[\[(]?(\d{1,2}:\d{2}(?::\d{2})?)[\])]?\s*[-–—|]?\s*"#)
    private static let numbering = try! NSRegularExpression(
        pattern: #"^\s*(?:\d{1,3}[.)\]]|[-•*])\s+"#)
    private static let url = try! NSRegularExpression(
        pattern: #"^https?://\S+$"#)
    private static let headerWords = ["track list", "tracklist", "playlist", "setlist"]

    public static func isURL(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return url.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }

    /// "1:02" → 62, "01:02:03" → 3723. Minutes and seconds must be two digits.
    public static func parseTimestamp(_ s: String) -> Double? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var values: [Double] = []
        for (i, part) in parts.enumerated() {
            guard !part.isEmpty, part.allSatisfy(\.isNumber) else { return nil }
            if i > 0 && part.count != 2 { return nil }
            values.append(Double(part)!)
        }
        return values.reduce(0) { $0 * 60 + $1 }
    }

    /// Strips timestamps, numbering and header lines. Returns nil for lines that are not tracks.
    public static func clean(_ line: String) -> ParsedLine? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if text.count < 40, headerWords.contains(where: { lower.contains($0) }) {
            return nil
        }

        var start: Double?
        if let match = timestamp.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let whole = Range(match.range, in: text),
           let stamp = Range(match.range(at: 1), in: text) {
            start = parseTimestamp(String(text[stamp]))
            text.removeSubrange(whole)
        }
        if let match = numbering.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let whole = Range(match.range, in: text) {
            text.removeSubrange(whole)
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return ParsedLine(start: start, query: text)
    }

    /// All track queries in the text, in order, deduplicated case-insensitively.
    public static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in lines(of: text) {
            guard let parsed = clean(raw) else { continue }
            let key = parsed.query.lowercased()
            if seen.insert(key).inserted {
                out.append(parsed.query)
            }
        }
        return out
    }

    /// Timestamped lines when the text contains a tracklist (3 or more), else nil.
    public static func findTracklist(in text: String) -> [ParsedLine]? {
        let stamped = lines(of: text).compactMap(clean).filter { $0.start != nil }
        return stamped.count >= 3 ? stamped : nil
    }

    private static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }
}
