import Foundation

/// What we need from a YouTube video before identifying it: title, text that might hold a tracklist, length.
public struct MixInfo: Codable, Equatable, Sendable {
    public let title: String
    public let description: String
    public let duration: Double
    public let comments: [String]

    public init(title: String, description: String, duration: Double, comments: [String]) {
        self.title = title
        self.description = description
        self.duration = duration
        self.comments = comments
    }
}

/// Fetches a mix's metadata and audio with yt-dlp.
public struct MixFetcher: Sendable {
    public let runner: CommandRunning
    public let locator: ToolLocator

    public init(runner: CommandRunning, locator: ToolLocator) {
        self.runner = runner
        self.locator = locator
    }

    public static func infoArguments(url: URL) -> [String] {
        [
            "-J", "--no-playlist", "--write-comments",
            "--extractor-args", "youtube:max_comments=100,all,0,0;comment_sort=top",
            url.absoluteString,
        ]
    }

    public static func parseInfo(_ data: Data) throws -> MixInfo {
        struct Raw: Decodable {
            struct Comment: Decodable { let text: String? }
            let title: String?
            let description: String?
            let duration: Double?
            let comments: [Comment]?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return MixInfo(
            title: raw.title ?? "Untitled",
            description: raw.description ?? "",
            duration: raw.duration ?? 0,
            comments: (raw.comments ?? []).compactMap(\.text))
    }

    public func fetchInfo(url: URL) async throws -> MixInfo {
        let ytDlp = try locator.url(for: .ytDlp)
        let result = try await runner.run(ytDlp, arguments: Self.infoArguments(url: url), onLine: nil)
        guard result.exitCode == 0 else {
            throw ToolError.failed(.ytDlp, exitCode: result.exitCode, stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try Self.parseInfo(Data(result.stdout.utf8))
    }

    /// Best audio, converted to 44.1 kHz mono WAV, which is what ShazamKit and Chromaprint want.
    public static func audioArguments(url: URL, output: URL, ffmpeg: URL) -> [String] {
        [
            "--no-playlist", "-f", "bestaudio/best", "-x", "--audio-format", "wav",
            "--postprocessor-args", "ffmpeg:-ar 44100 -ac 1",
            "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
            "-o", output.path,
            url.absoluteString,
        ]
    }

    public func fetchAudio(url: URL, to output: URL, onLine: (@Sendable (String) -> Void)?) async throws {
        let ytDlp = try locator.url(for: .ytDlp)
        let ffmpeg = try locator.url(for: .ffmpeg)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = try await runner.run(ytDlp, arguments: Self.audioArguments(url: url, output: output, ffmpeg: ffmpeg), onLine: onLine)
        guard result.exitCode == 0 else {
            throw ToolError.failed(.ytDlp, exitCode: result.exitCode, stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// Thin ffmpeg wrapper for the two operations identification needs.
public struct FFmpeg: Sendable {
    public let runner: CommandRunning
    public let locator: ToolLocator

    public init(runner: CommandRunning, locator: ToolLocator) {
        self.runner = runner
        self.locator = locator
    }

    /// Writes `length` seconds starting at `start` as 44.1 kHz mono.
    public func cut(input: URL, start: Double, length: Double, output: URL) async throws {
        let ffmpeg = try locator.url(for: .ffmpeg)
        let args = [
            "-y", "-hide_banner", "-loglevel", "error",
            "-ss", Self.seconds(start), "-t", Self.seconds(length),
            "-i", input.path, "-ar", "44100", "-ac", "1", output.path,
        ]
        let result = try await runner.run(ffmpeg, arguments: args, onLine: nil)
        guard result.exitCode == 0 else {
            throw ToolError.failed(.ffmpeg, exitCode: result.exitCode, stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Parses `Duration: hh:mm:ss.cc` from ffmpeg's input banner (ffmpeg exits non-zero with no output file, that is expected).
    public func duration(of file: URL) async throws -> Double {
        let ffmpeg = try locator.url(for: .ffmpeg)
        let result = try await runner.run(ffmpeg, arguments: ["-hide_banner", "-i", file.path], onLine: nil)
        let text = result.stderr + result.stdout
        guard let range = text.range(of: #"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)"#, options: .regularExpression) else {
            throw ToolError.failed(.ffmpeg, exitCode: result.exitCode, stderr: "could not read duration of \(file.lastPathComponent)")
        }
        let parts = text[range].dropFirst("Duration: ".count).split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else {
            throw ToolError.failed(.ffmpeg, exitCode: result.exitCode, stderr: "could not read duration of \(file.lastPathComponent)")
        }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    /// Adds ID3 BPM and key tags, keeping audio and cover art untouched. Rewrites the file in place.
    public func writeTags(file: URL, bpm: Int, key: String) async throws {
        let ffmpeg = try locator.url(for: .ffmpeg)
        let temp = file.deletingLastPathComponent().appendingPathComponent(".tagging-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: temp) }
        let args = [
            "-y", "-hide_banner", "-loglevel", "error",
            "-i", file.path, "-map", "0", "-c", "copy", "-id3v2_version", "3",
            "-metadata", "TBPM=\(bpm)", "-metadata", "TKEY=\(key)",
            temp.path,
        ]
        let result = try await runner.run(ffmpeg, arguments: args, onLine: nil)
        guard result.exitCode == 0, FileManager.default.fileExists(atPath: temp.path) else {
            throw ToolError.failed(.ffmpeg, exitCode: result.exitCode, stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
    }

    private static func seconds(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
