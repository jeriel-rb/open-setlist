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

    /// yt-dlp output template stem without extension: `NN - <query>` or `NN - %(title).120B` for URLs.
    /// A literal `%` in the query is doubled so yt-dlp does not read it as a template field.
    public var fileStem: String {
        let prefix = String(format: "%02d - ", index)
        if TrackParser.isURL(query) {
            return prefix + "%(title).120B"
        }
        return prefix + JobStore.sanitizeFileName(query).replacingOccurrences(of: "%", with: "%%")
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

    public init(name: String, kind: JobKind, sourceURL: URL? = nil, tracks: [Track]) {
        self.id = UUID()
        self.name = name
        self.kind = kind
        self.createdAt = Date()
        self.sourceURL = sourceURL
        self.tracks = tracks
    }
}


public extension Job {
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
