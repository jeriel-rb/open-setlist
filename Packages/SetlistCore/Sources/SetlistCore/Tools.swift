import Foundation

/// The command-line tools Setlist drives.
public enum Tool: String, Sendable, CaseIterable {
    case ytDlp = "yt-dlp"
    case ffmpeg
    case fpcalc
}

public enum ToolError: Error, LocalizedError, Equatable {
    case notFound(Tool, searched: [String])
    case failed(Tool, exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(tool, searched):
            return "\(tool.rawValue) was not found. Looked in: \(searched.joined(separator: ", "))"
        case let .failed(tool, code, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(tool.rawValue) exited with code \(code)." + (detail.isEmpty ? "" : " \(detail)")
        }
    }
}

/// Finds a tool binary: user override, then the app bundle, then common install paths.
public struct ToolLocator: Sendable {
    public let overrideDir: URL?
    public let bundleBinDir: URL?
    public let searchPaths: [URL]

    public init(
        overrideDir: URL?,
        bundleBinDir: URL?,
        searchPaths: [URL] = [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
    ) {
        self.overrideDir = overrideDir
        self.bundleBinDir = bundleBinDir
        self.searchPaths = searchPaths
    }

    /// `~/Library/Application Support/Setlist/bin` override, the running bundle's `Resources/bin`, then PATH-style fallbacks.
    public static func standard() -> ToolLocator {
        ToolLocator(overrideDir: Self.applicationSupportBinDir, bundleBinDir: Bundle.main.resourceURL?.appendingPathComponent("bin"))
    }

    public static var applicationSupportBinDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Setlist/bin", isDirectory: true)
    }

    public func url(for tool: Tool) throws -> URL {
        let dirs = [overrideDir, bundleBinDir].compactMap { $0 } + searchPaths
        for dir in dirs {
            let candidate = dir.appendingPathComponent(tool.rawValue)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw ToolError.notFound(tool, searched: dirs.map(\.path))
    }
}

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    /// Runs the executable to completion. `onLine` receives each stdout line as it arrives
    /// (split on both `\n` and `\r`, so progress bars stream too).
    func run(_ executable: URL, arguments: [String], onLine: (@Sendable (String) -> Void)?) async throws -> CommandResult
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ executable: URL, arguments: [String], onLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stdout = OutputAccumulator(onLine: onLine)
        let stderr = OutputAccumulator(onLine: nil)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdout.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderr.append(handle.availableData)
        }

        let exitCode: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { p in
                    continuation.resume(returning: p.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            // Stop the child so the continuation resumes promptly with a non-zero status.
            if process.isRunning { process.terminate() }
        }

        // Drain whatever is left after termination, then stop the handlers.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdout.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        stdout.finish()

        return CommandResult(exitCode: exitCode, stdout: stdout.text, stderr: stderr.text)
    }
}

/// Collects raw bytes and emits complete lines.
private final class OutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pending = ""
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        guard let onLine else { lock.unlock(); return }
        pending += String(decoding: chunk, as: UTF8.self)
        var lines: [String] = []
        while let idx = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(pending[..<idx])
            pending.removeSubrange(...idx)
            if !line.isEmpty { lines.append(line) }
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func finish() {
        lock.lock()
        let rest = pending
        pending = ""
        lock.unlock()
        if !rest.isEmpty { onLine?(rest) }
    }
}
