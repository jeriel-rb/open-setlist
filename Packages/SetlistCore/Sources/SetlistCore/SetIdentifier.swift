import Foundation

public struct IdentifyResult: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case description, comments, shazam
    }

    public let tracks: [Track]
    public let source: Source

    public init(tracks: [Track], source: Source) {
        self.tracks = tracks
        self.source = source
    }
}

/// Turns a mix into a tracklist: a posted tracklist in the description or comments when there is one,
/// otherwise ShazamKit on a window from every slice of the audio.
public struct SetIdentifier: Sendable {
    public enum Error: Swift.Error, LocalizedError {
        /// Not one slice could be matched because the matcher itself kept failing (network, entitlement).
        case everySliceFailed(underlying: Swift.Error)

        public var errorDescription: String? {
            switch self {
            case let .everySliceFailed(underlying):
                "ShazamKit could not identify anything: \(underlying.localizedDescription) " +
                "Check that the ShazamKit app service is enabled for this app's App ID and that you are online."
            }
        }
    }

    public let matcher: SliceMatching
    public let sliceSeconds: Double
    public let windowOffset: Double
    public let windowSeconds: Double
    public let delay: Duration

    public init(matcher: SliceMatching, sliceSeconds: Double = 30, windowOffset: Double = 9, windowSeconds: Double = 12, delay: Duration = .milliseconds(1500)) {
        self.matcher = matcher
        self.sliceSeconds = sliceSeconds
        self.windowOffset = windowOffset
        self.windowSeconds = windowSeconds
        self.delay = delay
    }

    private static let remixWords = try! NSRegularExpression(pattern: #"(?i)\b(remix|flip|edit|bootleg|mashup|version|rework|vip)\b"#)

    /// A tracklist from the description first, then from the comments, or nil when neither has one.
    public static func tracksFromText(_ info: MixInfo) -> (tracks: [Track], source: IdentifyResult.Source)? {
        if let lines = TrackParser.findTracklist(in: info.description) {
            return (toTracks(lines), .description)
        }
        for comment in info.comments {
            if let lines = TrackParser.findTracklist(in: comment) {
                return (toTracks(lines), .comments)
            }
        }
        return nil
    }

    private static func toTracks(_ lines: [ParsedLine]) -> [Track] {
        lines.enumerated().map { i, line in Track(index: i + 1, query: line.query, start: line.start, confidence: .fromText) }
    }

    /// Shazam every slice. Matcher errors count as "no match" so one network hiccup does not abort the run.
    public func identify(wav: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> [IdentifiedTrack] {
        let reader = try AudioWindowReader(fileURL: wav)
        var starts: [Double] = []
        var start = 0.0
        while start + windowOffset + windowSeconds <= reader.duration {
            starts.append(start)
            start += sliceSeconds
        }
        guard !starts.isEmpty else {
            progress(1)
            return []
        }

        var slices: [SliceMatch] = []
        var failures = 0
        var lastError: Swift.Error?
        for (i, sliceStart) in starts.enumerated() {
            let buffer = try reader.buffer(start: sliceStart + windowOffset, length: windowSeconds)
            var hit: Hit?
            do {
                hit = try await matcher.match(buffer)
            } catch {
                failures += 1
                lastError = error
            }
            slices.append(SliceMatch(start: sliceStart, hit: hit))
            progress(Double(i + 1) / Double(starts.count))
            if i + 1 < starts.count, delay > .zero {
                try? await Task.sleep(for: delay)
            }
        }
        if failures == starts.count, let lastError {
            throw Error.everySliceFailed(underlying: lastError)
        }
        return MatchMerger.merge(slices, totalDuration: reader.duration)
    }

    /// Shazam hits become tracks: `.high` when the catalog title already names a remix, else `.medium`.
    public static func toTracks(_ identified: [IdentifiedTrack]) -> [Track] {
        identified.enumerated().map { i, item in
            let title = item.hit.title
            let isRemix = remixWords.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
            return Track(index: i + 1, query: item.query, start: item.start, confidence: isRemix ? .high : .medium)
        }
    }
}
