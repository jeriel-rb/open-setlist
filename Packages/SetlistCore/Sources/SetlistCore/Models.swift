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
    case pending, searching, downloading, done, failed, skipped
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

    public init(index: Int, query: String, start: Double? = nil, confidence: Confidence = .high) {
        self.id = UUID()
        self.index = index
        self.query = query
        self.start = start
        self.confidence = confidence
        self.status = .pending
    }

    /// yt-dlp output template stem without extension: `NN - <query>` or `NN - %(title).120B` for URLs.
    public var fileStem: String {
        let prefix = String(format: "%02d - ", index)
        if TrackParser.isURL(query) {
            return prefix + "%(title).120B"
        }
        return prefix + JobStore.sanitizeFileName(query)
    }
}

public enum JobKind: String, Codable, Sendable {
    case pasteList, youtubeSet
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
