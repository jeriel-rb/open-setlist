import Foundation

/// Owns the `~/Documents/Setlist/<job>/` layout.
public struct JobStore: Sendable {
    public static let defaultRoot: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Setlist", isDirectory: true)

    public static let jobFileName = "job.json"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Makes a string safe as a single path component.
    public static func sanitizeFileName(_ s: String) -> String {
        let forbidden: Set<Character> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]
        let replaced = String(s.map { forbidden.contains($0) ? "-" : $0 })
        let collapsed = replaced
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let trimmed = String(collapsed.prefix(150)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "untitled" : trimmed
    }

    /// The job's folder, created on first call and remembered in `job.directoryName`.
    /// A name already used by a different job gets a " 2", " 3", … suffix.
    public func directory(for job: inout Job) throws -> URL {
        if let name = job.directoryName {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = Self.sanitizeFileName(job.name)
        var candidate = base
        var n = 2
        while isTaken(candidate, by: job.id) {
            candidate = "\(base) \(n)"
            n += 1
        }
        job.directoryName = candidate
        let dir = root.appendingPathComponent(candidate, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func isTaken(_ name: String, by id: UUID) -> Bool {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        if let existing = try? load(from: dir), existing.id == id { return false }
        return true
    }

    public func save(_ job: Job) throws {
        var job = job
        let dir = try directory(for: &job)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(job).write(to: dir.appendingPathComponent(Self.jobFileName), options: .atomic)
    }

    /// Every saved job under the root, newest first.
    public func loadAll() throws -> [Job] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let dirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return dirs.compactMap { try? load(from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func load(from dir: URL) throws -> Job {
        let data = try Data(contentsOf: dir.appendingPathComponent(Self.jobFileName))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Job.self, from: data)
    }

    /// `tracklist.txt`: one line per track, prefixed with `mm:ss ` when a start time is known.
    public func writeTracklist(_ job: Job) throws {
        var job = job
        let dir = try directory(for: &job)
        let lines = job.tracks.map { track -> String in
            if let start = track.start {
                return "\(Self.timestamp(start)) \(track.query)"
            }
            return track.query
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("tracklist.txt"), atomically: true, encoding: .utf8)
    }

    /// `failed.txt` lists tracks with `.failed` status; the file is removed when there are none.
    public func writeFailed(_ job: Job) throws {
        var job = job
        let dir = try directory(for: &job)
        let file = dir.appendingPathComponent("failed.txt")
        let failed = job.tracks.filter { $0.status == .failed }.map(\.query)
        if failed.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else {
            try (failed.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// 90 → "01:30", 3723 → "1:02:03".
    public static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
