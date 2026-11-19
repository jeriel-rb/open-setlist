import Foundation

/// Downloads the latest standalone yt-dlp into the user's override directory, where `ToolLocator`
/// prefers it over the copy bundled with the app.
public struct YtDlpUpdater: Sendable {
    public enum Error: Swift.Error, Equatable, LocalizedError {
        case httpStatus(Int)
        case notHTTP

        public var errorDescription: String? {
            switch self {
            case let .httpStatus(code): "yt-dlp download failed (HTTP \(code))."
            case .notHTTP: "yt-dlp download failed (no HTTP response)."
            }
        }
    }

    public static let downloadURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    public let session: URLSession
    public let overrideDir: URL

    public init(session: URLSession = .shared, overrideDir: URL = ToolLocator.applicationSupportBinDir) {
        self.session = session
        self.overrideDir = overrideDir
    }

    public static let latestReleaseURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest")!

    /// The version a release page address names: `…/releases/tag/2026.10.26` → "2026.10.26".
    public static func version(fromReleaseURL url: URL) -> String? {
        let parts = url.pathComponents
        guard let tag = parts.firstIndex(of: "tag"), tag + 1 < parts.count else { return nil }
        return parts[tag + 1]
    }

    /// The newest released version, read from where GitHub redirects "latest" to. No download involved.
    public func latestVersion() async throws -> String? {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        return response.url.flatMap(Self.version(fromReleaseURL:))
    }

    /// Fetches the binary, writes it atomically as `overrideDir/yt-dlp`, and marks it executable.
    public func update() async throws -> URL {
        let (data, response) = try await session.data(from: Self.downloadURL)
        guard let http = response as? HTTPURLResponse else { throw Error.notHTTP }
        guard (200..<300).contains(http.statusCode) else { throw Error.httpStatus(http.statusCode) }

        try FileManager.default.createDirectory(at: overrideDir, withIntermediateDirectories: true)
        let destination = overrideDir.appendingPathComponent(Tool.ytDlp.rawValue)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        // Files written by the app carry no quarantine flag, but clear it defensively if one exists.
        removeQuarantine(destination)
        return destination
    }

    private func removeQuarantine(_ url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = removexattr(path, "com.apple.quarantine", 0)
        }
    }

    /// Output of `yt-dlp --version` for whichever copy the locator resolves, nil when unavailable.
    public func installedVersion(runner: CommandRunning, locator: ToolLocator) async -> String? {
        guard let ytDlp = try? locator.url(for: .ytDlp),
              let result = try? await runner.run(ytDlp, arguments: ["--version"], onLine: nil),
              result.exitCode == 0 else { return nil }
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }
}
