import Foundation

/// How downloaded files are named: which of number, artist and title appear, in what order,
/// what goes between them, and any fixed text before or after.
public struct FileNameFormat: Codable, Equatable, Sendable {
    public enum Part: String, Codable, CaseIterable, Sendable {
        case number, artist, title
    }

    /// All three parts in the order they appear.
    public var order: [Part] = [.number, .artist, .title]
    /// The parts that are actually used.
    public var included: Set<Part> = [.number, .artist, .title]
    public var separator: String = " - "
    /// 2 gives "01", 3 gives "001", 1 gives "1".
    public var numberDigits: Int = 2
    public var prefix: String = ""
    public var suffix: String = ""

    public init() {}

    /// `01 - Artist - Title`.
    public static let standard = FileNameFormat()

    /// Stands in for the video title while the rest of the name is cleaned up.
    private static let linkTitleMarker = "\u{FFFC}"
    private static let linkTitleField = "%(title).120B"
    private static let dash = try! NSRegularExpression(pattern: #"\s[-–—]\s"#)

    /// "Artist - Title" split at the first dash. Text without one is all title.
    static func split(_ query: String) -> (artist: String?, title: String) {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard let match = dash.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return (nil, text) }
        let artist = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let title = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !artist.isEmpty, !title.isEmpty else { return (nil, text) }
        return (artist, title)
    }

    /// The file name without extension, as a yt-dlp output template: safe as one path component and with
    /// any literal `%` doubled. For a link, the video's own title stands where artist and title would go.
    public func stem(index: Int, query: String) -> String {
        let isLink = TrackParser.isURL(query)
        let (artist, title) = Self.split(query)
        var pieces: [String] = []
        var namePlaced = false
        for part in order where included.contains(part) {
            switch part {
            case .number:
                pieces.append(String(format: "%0\(max(1, min(numberDigits, 6)))d", index))
            case .artist, .title:
                if isLink {
                    if !namePlaced { pieces.append(Self.linkTitleMarker) }
                    namePlaced = true
                } else if part == .title {
                    pieces.append(title)
                    namePlaced = true
                } else if let artist {
                    pieces.append(artist)
                    namePlaced = true
                }
            }
        }
        // Nothing included, or an artist was asked for and the text has none: name the file after the title.
        // A number on its own is a choice and stays as it is.
        if !namePlaced, included != [.number] {
            pieces.append(isLink ? Self.linkTitleMarker : title)
        }
        let name = JobStore.sanitizeFileName(prefix + pieces.joined(separator: separator) + suffix)
        return name.replacingOccurrences(of: "%", with: "%%")
            .replacingOccurrences(of: Self.linkTitleMarker, with: Self.linkTitleField)
    }

    /// What a file would be called, for showing in Settings.
    public var example: String {
        stem(index: 1, query: "XG - LEFT RIGHT").replacingOccurrences(of: "%%", with: "%") + ".mp3"
    }

    /// Without the number, two songs with the same name would be saved as one file.
    public var canCollide: Bool { !included.contains(.number) }
}
