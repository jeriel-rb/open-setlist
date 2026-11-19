import Foundation

public enum Confidence: String, Codable, Sendable {
    /// Exact match: user-typed, Shazam matched a remix title, or a fingerprint-verified candidate.
    case high
    /// Shazam returned the original while the set may use a remix we could not verify.
    case medium
    /// Nothing identified; skipped on download unless the user edits it.
    case low
    /// Parsed from the video description or a comment.
    case fromText
}

public enum TrackStatus: String, Codable, Sendable {
    case pending, searching, downloading, analyzing, done, failed, skipped, cancelled

    /// True while the track still has work ahead of it.
    public var isActive: Bool { [.pending, .searching, .downloading, .analyzing].contains(self) }
}

/// Tempo and key of a downloaded file.
public struct TrackAnalysis: Codable, Equatable, Sendable {
    public let bpm: Int
    /// Camelot wheel code, e.g. "8A" (A minor) or "8B" (C major).
    public let camelot: String
    /// Musical name, e.g. "A minor".
    public let keyName: String

    public init(bpm: Int, camelot: String, keyName: String) {
        self.bpm = bpm
        self.camelot = camelot
        self.keyName = keyName
    }

    /// ID3 TKEY form derived from `keyName`: "A minor" → "Am", "F# major" → "F#".
    public var id3Key: String {
        let parts = keyName.split(separator: " ")
        guard let note = parts.first else { return keyName }
        return String(note) + (parts.last == "minor" ? "m" : "")
    }
}

public struct Track: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// 1-based position in the list.
    public var index: Int
    /// "Artist - Title" search text, or a direct URL.
    public var query: String
    /// Start offset in the source mix, YouTube Set jobs only.
    public var start: Double?
    public var confidence: Confidence
    public var status: TrackStatus
    public var outputPath: String?
    /// Human-readable detail (matched upload title, failure reason).
    public var note: String?
    /// What is happening right now ("Downloading 45%"); nil when idle or finished.
    public var activity: String?
    public var bpm: Int?
    /// Camelot code, e.g. "8A".
    public var key: String?
    public var keyName: String?

    public init(index: Int, query: String, start: Double? = nil, confidence: Confidence = .high) {
        self.id = UUID()
        self.index = index
        self.query = query
        self.start = start
        self.confidence = confidence
        self.status = .pending
    }

    /// The file name stem in the standard format, `NN - Artist - Title`. Downloads use
    /// `DownloadOptions.fileNameFormat`, which the user can change.
    public var fileStem: String {
        FileNameFormat.standard.stem(index: index, query: query)
    }
}

public enum JobKind: String, Codable, Sendable {
    /// Free-form pasted text.
    case pasteList
    /// Pasted YouTube / SoundCloud / Spotify links.
    case link
    /// A single YouTube mix identified track by track.
    case youtubeSet
}

public struct Job: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: JobKind
    public var createdAt: Date
    public var sourceURL: URL?
    public var tracks: [Track]
    /// Folder name under the store root, assigned by `JobStore.directory(for:)`.
    public var directoryName: String?
    /// Identification checkpoint of a YouTube Set whose songs are found by listening to the mix.
    public var mix: MixState?

    public init(name: String, kind: JobKind, sourceURL: URL? = nil, tracks: [Track]) {
        self.id = UUID()
        self.name = name
        self.kind = kind
        self.createdAt = Date()
        self.sourceURL = sourceURL
        self.tracks = tracks
    }
}


/// How far the identification of a mix has got. Saved in `job.json` after every step, so a stopped,
/// failed or interrupted run continues from here instead of starting over.
public struct MixState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case downloadingAudio, identifying, finished
    }

    public static let fileName = "mix.wav"
    public static let keptFileName = "original mix.wav"

    public var phase: Phase = .downloadingAudio
    /// 0…1 while the mix audio downloads.
    public var audioProgress: Double?
    /// Length of the mix in seconds, known once its audio is on disk.
    public var duration: Double?
    /// How many slices the mix divides into.
    public var sliceCount: Int?
    /// One entry per slice already sent to Shazam, in order.
    public var slices: [SliceMatch] = []
    /// Why the run stopped early, shown with a Resume button.
    public var message: String?

    public init() {}

    /// 0…1 over the slices, nil before the mix has been measured.
    public var identifyProgress: Double? {
        guard let sliceCount, sliceCount > 0 else { return nil }
        return min(1, Double(slices.count) / Double(sliceCount))
    }
}

public extension Job {
    /// True for a mix whose identification stopped before the end and can be continued.
    var canResumeMix: Bool { mix.map { $0.phase != .finished } ?? false }

    static let interruptedNote = "Interrupted when the app quit"

    var hasActiveTracks: Bool { tracks.contains { $0.status.isActive } }

    /// Tracks that a retry would run again.
    var retryableCount: Int { tracks.filter { $0.status == .failed || $0.status == .cancelled }.count }

    /// A job loaded from disk with tracks still "in progress" was cut off; mark those tracks cancelled.
    func markingInterrupted() -> Job {
        var copy = self
        for i in copy.tracks.indices where copy.tracks[i].status.isActive {
            copy.tracks[i].status = .cancelled
            copy.tracks[i].activity = nil
            copy.tracks[i].note = Self.interruptedNote
        }
        return copy
    }

    /// Failed and cancelled tracks go back to pending so `Downloader.downloadAll` picks them up again.
    func resettingForRetry() -> Job {
        var copy = self
        for i in copy.tracks.indices where copy.tracks[i].status == .failed || copy.tracks[i].status == .cancelled {
            copy.tracks[i].status = .pending
            copy.tracks[i].note = nil
            copy.tracks[i].activity = nil
        }
        return copy
    }
}
