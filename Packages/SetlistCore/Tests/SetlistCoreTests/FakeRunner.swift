import Foundation
@testable import SetlistCore

/// Records every invocation and replays scripted results in order.
/// When the script runs out, the `fallback` closure decides (default: exit 0, empty output).
final class FakeRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var scripted: [CommandResult]
    private var recorded: [Call] = []
    var fallback: @Sendable (Call) -> CommandResult = { _ in CommandResult(exitCode: 0, stdout: "", stderr: "") }
    /// Lines to stream through `onLine` for each call, matched by call index.
    var streamed: [Int: [String]] = [:]
    /// Answers the "five results from each site" searches a download starts with, outside the script and
    /// the recorded calls. The default finds nothing, which sends the download down its plain
    /// `ytsearch1` / `scsearch1` path. Set to nil to script and record those searches like any call.
    var searchResult: (@Sendable (Call) -> CommandResult)? = { _ in CommandResult(exitCode: 0, stdout: "", stderr: "") }
    /// Answers "read this song's or playlist's names" runs the same way: outside the script and the
    /// recorded calls, finding nothing by default. Set to nil to script and record them.
    var nameResult: (@Sendable (Call) -> CommandResult)? = { _ in CommandResult(exitCode: 0, stdout: "", stderr: "") }
    /// Simulated run time; cancellation interrupts it like a terminated process would.
    var delay: Duration = .zero

    init(results: [CommandResult] = []) {
        self.scripted = results
    }

    var calls: [Call] { lock.withLock { recorded } }

    func run(_ executable: URL, arguments: [String], onLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
        let call = Call(executable: executable.lastPathComponent, arguments: arguments)
        if let searchResult, let target = arguments.last, target.hasPrefix("ytsearch5:") || target.hasPrefix("scsearch5:") {
            return searchResult(call)
        }
        if let nameResult, arguments.contains("--skip-download") {
            let result = nameResult(call)
            if let onLine { result.stdout.split(separator: "\n").forEach { onLine(String($0)) } }
            return result
        }
        let (result, index): (CommandResult, Int) = lock.withLock {
            recorded.append(call)
            let idx = recorded.count - 1
            if scripted.isEmpty { return (fallback(call), idx) }
            return (scripted.removeFirst(), idx)
        }
        if let lines = streamed[index] {
            lines.forEach { onLine?($0) }
        } else if let onLine {
            result.stdout.split(separator: "\n").forEach { onLine(String($0)) }
        }
        if delay > .zero {
            do { try await Task.sleep(for: delay) } catch { return CommandResult(exitCode: 15, stdout: "", stderr: "terminated") }
        }
        return result
    }
}

extension CommandResult {
    static func ok(_ stdout: String = "") -> CommandResult { CommandResult(exitCode: 0, stdout: stdout, stderr: "") }
    static func fail(_ stderr: String = "boom", code: Int32 = 1) -> CommandResult { CommandResult(exitCode: code, stdout: "", stderr: stderr) }
}

/// A locator whose tools all live in one temp directory of executable stubs.
enum TestTools {
    static func locator() throws -> ToolLocator {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TestTools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for tool in Tool.allCases {
            let file = dir.appendingPathComponent(tool.rawValue)
            try "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return ToolLocator(overrideDir: nil, bundleBinDir: dir, searchPaths: [])
    }
}
