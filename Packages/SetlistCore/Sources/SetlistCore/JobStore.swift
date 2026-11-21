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

    /// File names are capped well under the 255-byte limit, leaving room for the `NN - ` prefix and
    /// yt-dlp's temporary extensions (`.f251.webm.part`).
    public static let maxFileNameBytes = 180

    /// Makes a string safe as a single path component: no separators, no leading dot (hidden files,
    /// `.` and `..`), at most 150 characters and `maxFileNameBytes` UTF-8 bytes.
    public static func sanitizeFileName(_ s: String) -> String {
        let forbidden: Set<Character> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]
        let replaced = String(s.map { forbidden.contains($0) ? "-" : $0 })
        let collapsed = replaced
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        var name = Substring(collapsed.drop { $0 == "." || $0 == " " }.prefix(150))
        while name.utf8.count > maxFileNameBytes { name.removeLast() }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
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
        let candidate = availableDirectoryName(for: job.name, excluding: job.id)
        job.directoryName = candidate
        let dir = root.appendingPathComponent(candidate, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Renames the job. With `moveFolder` (the default) the folder is renamed to match right away;
    /// pass false while files are still being written and call `syncDirectory` afterwards.
    public func rename(_ job: inout Job, to newName: String, moveFolder: Bool = true) throws {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != job.name else { return }
        _ = try directory(for: &job)
        job.name = name
        if moveFolder {
            try syncDirectory(&job)
        } else {
            try save(job)
        }
    }

    /// Moves the job's folder so it matches the job's name, if it does not already.
    public func syncDirectory(_ job: inout Job) throws {
        let oldDir = try directory(for: &job)
        let newDirName = availableDirectoryName(for: job.name, excluding: job.id)
        if newDirName != job.directoryName {
            let newDir = root.appendingPathComponent(newDirName, isDirectory: true)
            try FileManager.default.moveItem(at: oldDir, to: newDir)
            job.directoryName = newDirName
        }
        try save(job)
    }

    private func availableDirectoryName(for name: String, excluding id: UUID) -> String {
        let base = Self.sanitizeFileName(name)
        var candidate = base
        var n = 2
        while isTaken(candidate, by: id) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
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
        return dirs.compactMap { dir -> Job? in
            guard var job = try? load(from: dir) else { return nil }
            // The folder may have been renamed in Finder: where the job actually is wins over what it
            // remembers, and the job takes the folder's new name.
            if job.directoryName != dir.lastPathComponent {
                job.directoryName = dir.lastPathComponent
                job.name = dir.lastPathComponent
            }
            return job
        }
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
                return "\(Self.timestamp(start)) \(track.displayName)"
            }
            return track.displayName
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

public extension JobStore {
    /// Renames the job's downloaded files to `format` and remembers it on the job. Files that are missing
    /// are left alone. When two songs would get the same name, the later ones get " (2)", " (3)", ….
    /// Returns how many files were renamed.
    @discardableResult
    func renameFiles(of job: inout Job, to format: FileNameFormat) throws -> Int {
        let dir = try directory(for: &job)
        let fm = FileManager.default
        let old = job.fileNameFormat ?? .standard

        struct Move { let track: Int; let from: URL; var to: URL }
        var moves: [Move] = []
        var taken = Set<String>()
        for i in job.tracks.indices {
            guard job.tracks[i].status == .done, let saved = job.tracks[i].outputPath else { continue }
            let from = dir.appendingPathComponent(URL(fileURLWithPath: saved).lastPathComponent)
            guard fm.fileExists(atPath: from.path) else { continue }
            let track = job.tracks[i]
            // A link's song name is not in the job; it is in the file name the old format produced.
            let currentStem = from.deletingPathExtension().lastPathComponent
            let text: String
            if TrackParser.isURL(track.query) {
                // A name left blank (the field was emptied before the download) is no name.
                let known = track.songName.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                text = known ?? old.linkTitle(inFileName: currentStem, index: track.index) ?? currentStem
                job.tracks[i].songName = text
            } else {
                text = track.query
            }
            let base = format.fileName(index: track.index, text: text)
            var name = base
            var n = 2
            while !taken.insert(name.lowercased()).inserted {
                name = "\(base) (\(n))"
                n += 1
            }
            moves.append(Move(track: i, from: from, to: dir.appendingPathComponent(name).appendingPathExtension(from.pathExtension)))
        }

        // Two steps, through temporary names, so "01 - A" → "02 - A" cannot land on a file that is itself about to move.
        let sources = Set(moves.map { $0.from.standardizedFileURL.path.lowercased() })
        let token = UUID().uuidString
        var staged: [(Move, URL)] = []
        for (n, move) in moves.enumerated() where move.from.lastPathComponent != move.to.lastPathComponent {
            // Never overwrite a file that is not part of this rename.
            var move = move
            var k = 2
            let stem = move.to.deletingPathExtension().lastPathComponent
            while fm.fileExists(atPath: move.to.path), !sources.contains(move.to.standardizedFileURL.path.lowercased()) {
                move.to = dir.appendingPathComponent("\(stem) (\(k))").appendingPathExtension(move.from.pathExtension)
                k += 1
            }
            let temp = dir.appendingPathComponent(".renaming-\(token)-\(n)")
            try fm.moveItem(at: move.from, to: temp)
            staged.append((move, temp))
        }
        for (move, temp) in staged {
            try fm.moveItem(at: temp, to: move.to)
            job.tracks[move.track].outputPath = move.to.path
        }
        job.fileNameFormat = format
        try save(job)
        return staged.count
    }
}

public extension JobStore {
    enum TrackFileError: Swift.Error, Equatable, LocalizedError {
        case emptyName
        case nameTaken(String)

        public var errorDescription: String? {
            switch self {
            case .emptyName: "Type a name first."
            case let .nameTaken(name): "The folder already has a file called “\(name)”."
            }
        }
    }

    /// The downloaded file of a track in the job's current folder, or nil when it has none or it is gone.
    private func file(of track: Track, in dir: URL) -> URL? {
        guard track.status == .done, let saved = track.outputPath else { return nil }
        let url = dir.appendingPathComponent(URL(fileURLWithPath: saved).lastPathComponent)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Gives one song a new name ("Artist - Title") and renames its file to match, in the job's own
    /// file-name format. A link keeps its address; a typed song's text becomes the new name.
    func renameTrack(_ id: Track.ID, in job: inout Job, to newName: String) throws {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TrackFileError.emptyName }
        guard let i = job.tracks.firstIndex(where: { $0.id == id }) else { return }
        let dir = try directory(for: &job)
        if let from = file(of: job.tracks[i], in: dir) {
            let format = job.fileNameFormat ?? .standard
            let to = dir.appendingPathComponent(format.fileName(index: job.tracks[i].index, text: name))
                .appendingPathExtension(from.pathExtension)
            if to.lastPathComponent != from.lastPathComponent {
                // A change of capitals only is the same file on this disk, not a clash.
                let sameFile = to.lastPathComponent.lowercased() == from.lastPathComponent.lowercased()
                guard sameFile || !FileManager.default.fileExists(atPath: to.path) else {
                    throw TrackFileError.nameTaken(to.lastPathComponent)
                }
                try FileManager.default.moveItem(at: from, to: to)
                job.tracks[i].outputPath = to.path
            }
        }
        if TrackParser.isURL(job.tracks[i].query) {
            job.tracks[i].songName = name
        } else {
            job.tracks[i].query = name
        }
        try save(job)
        try? writeTracklist(job)
    }

    /// Takes one song out of the job. Its file, when it has one, goes to the Trash (or to `discard`,
    /// which tests use in place of the Trash). The other songs keep their numbers.
    func deleteTrack(_ id: Track.ID, from job: inout Job, discard: ((URL) throws -> Void)? = nil) throws {
        guard let i = job.tracks.firstIndex(where: { $0.id == id }) else { return }
        let dir = try directory(for: &job)
        if let file = file(of: job.tracks[i], in: dir) {
            if let discard {
                try discard(file)
            } else {
                try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            }
        }
        job.tracks.remove(at: i)
        try save(job)
        try? writeTracklist(job)
        try? writeFailed(job)
    }

    /// Dates the job's files in list order, one second apart from when the job was made, so sorting the
    /// folder by date in Finder (oldest first) shows the songs in the order the app lists them. Downloads
    /// finish in any order, which leaves the files' own dates meaningless. Returns how many were dated.
    @discardableResult
    func stampListOrder(of job: Job) -> Int {
        var job = job
        guard let dir = try? directory(for: &job) else { return 0 }
        var stamped = 0
        for (position, track) in job.tracks.sorted(by: { $0.index < $1.index }).enumerated() {
            guard let file = file(of: track, in: dir) else { continue }
            let date = job.createdAt.addingTimeInterval(Double(position))
            if (try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: file.path)) != nil {
                stamped += 1
            }
        }
        return stamped
    }
}
