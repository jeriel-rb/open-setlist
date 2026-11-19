import Foundation

/// One Shazam catalog match.
public struct Hit: Codable, Equatable, Sendable {
    public let shazamID: String
    public let title: String
    public let artist: String
    public let confidence: Float?

    public init(shazamID: String, title: String, artist: String, confidence: Float?) {
        self.shazamID = shazamID
        self.title = title
        self.artist = artist
        self.confidence = confidence
    }
}

/// The result of matching one slice of the mix.
public struct SliceMatch: Codable, Equatable, Sendable {
    public let start: Double
    public let hit: Hit?

    public init(start: Double, hit: Hit?) {
        self.start = start
        self.hit = hit
    }
}

/// A song found in the mix, spanning `start..<end` seconds.
public struct IdentifiedTrack: Equatable, Sendable {
    public let start: Double
    public var end: Double
    public let hit: Hit

    public init(start: Double, end: Double, hit: Hit) {
        self.start = start
        self.end = end
        self.hit = hit
    }

    public var query: String { "\(hit.artist) - \(hit.title)" }
}

/// Collapses per-slice matches into a tracklist.
public enum MatchMerger {
    private struct Run {
        let hit: Hit
        let start: Double
        var slices: Int
    }

    /// Consecutive slices with the same Shazam ID form one track. Up to `gapTolerance` unmatched
    /// slices inside a run do not break it. A one-slice run sandwiched between two runs of the same
    /// other song is treated as noise and absorbed.
    public static func merge(_ slices: [SliceMatch], totalDuration: Double, gapTolerance: Int = 1) -> [IdentifiedTrack] {
        var runs: [Run] = []
        var current: Run?
        var gap = 0

        for slice in slices.sorted(by: { $0.start < $1.start }) {
            guard let hit = slice.hit else {
                gap += 1
                if gap > gapTolerance, let run = current {
                    runs.append(run)
                    current = nil
                }
                continue
            }
            gap = 0
            if var run = current, run.hit.shazamID == hit.shazamID {
                run.slices += 1
                current = run
            } else {
                if let run = current { runs.append(run) }
                current = Run(hit: hit, start: slice.start, slices: 1)
            }
        }
        if let run = current { runs.append(run) }

        runs = absorbSingletons(runs)

        return runs.enumerated().map { i, run in
            let end = i + 1 < runs.count ? runs[i + 1].start : totalDuration
            return IdentifiedTrack(start: run.start, end: end, hit: run.hit)
        }
    }

    private static func absorbSingletons(_ input: [Run]) -> [Run] {
        var runs = input
        var i = 1
        while i + 1 < runs.count {
            let prev = runs[i - 1], mid = runs[i], next = runs[i + 1]
            if mid.slices == 1, prev.hit.shazamID == next.hit.shazamID, prev.hit.shazamID != mid.hit.shazamID {
                runs[i - 1].slices += mid.slices + next.slices
                runs.removeSubrange(i...(i + 1))
                // Re-check the same position: the merged run may now sandwich another singleton.
                i = max(1, i - 1)
            } else {
                i += 1
            }
        }
        return runs
    }
}
