import XCTest
@testable import SetlistCore

final class ToolsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Creates `dir/name` as an executable shell stub that echoes `tag`.
    private func stub(_ dir: String, _ name: String, tag: String) throws -> URL {
        let d = root.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let file = d.appendingPathComponent(name)
        try "#!/bin/sh\necho \(tag)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    func testLocatorPrefersOverride() throws {
        let override = try stub("override", "yt-dlp", tag: "override")
        _ = try stub("bundle", "yt-dlp", tag: "bundle")
        let locator = ToolLocator(
            overrideDir: root.appendingPathComponent("override"),
            bundleBinDir: root.appendingPathComponent("bundle"),
            searchPaths: [])
        XCTAssertEqual(try locator.url(for: .ytDlp).path, override.path)
    }

    func testLocatorFallsBackToBundleThenSearchPaths() throws {
        let bundle = try stub("bundle", "ffmpeg", tag: "bundle")
        let search = try stub("search", "fpcalc", tag: "search")
        let locator = ToolLocator(
            overrideDir: root.appendingPathComponent("override"),  // does not exist
            bundleBinDir: root.appendingPathComponent("bundle"),
            searchPaths: [root.appendingPathComponent("search")])
        XCTAssertEqual(try locator.url(for: .ffmpeg).path, bundle.path)
        XCTAssertEqual(try locator.url(for: .fpcalc).path, search.path)
    }

    func testMissingToolThrows() throws {
        let locator = ToolLocator(
            overrideDir: root.appendingPathComponent("a"),
            bundleBinDir: root.appendingPathComponent("b"),
            searchPaths: [root.appendingPathComponent("c")])
        XCTAssertThrowsError(try locator.url(for: .ytDlp)) { error in
            guard case let ToolError.notFound(tool, searched) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(tool, .ytDlp)
            XCTAssertEqual(searched.count, 3)
            XCTAssertTrue(searched[0].hasSuffix("/a"))
            XCTAssertTrue(error.localizedDescription.contains("yt-dlp"))
        }
    }

    func testNonExecutableFileIsNotFound() throws {
        let d = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try "not a binary".write(to: d.appendingPathComponent("yt-dlp"), atomically: true, encoding: .utf8)
        let locator = ToolLocator(overrideDir: nil, bundleBinDir: d, searchPaths: [])
        XCTAssertThrowsError(try locator.url(for: .ytDlp))
    }

    func testProcessRunnerCapturesOutputAndStreamsLines() async throws {
        let runner = ProcessRunner()
        let collected = LineCollector()
        let result = try await runner.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'a\\nb\\n'; echo err >&2; exit 3"],
            onLine: { line in collected.append(line) })
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdout, "a\nb\n")
        XCTAssertTrue(result.stderr.contains("err"))
        XCTAssertEqual(collected.lines, ["a", "b"])
    }

    func testProcessRunnerTerminatesOnTaskCancellation() async throws {
        let runner = ProcessRunner()
        let started = Date()
        let task = Task {
            try await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], onLine: nil)
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = try? await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "sleep should have been terminated")
        XCTAssertNotEqual(result?.exitCode, 0)
    }

    func testProcessRunnerDoesNotRunWhenAlreadyCancelled() async throws {
        let runner = ProcessRunner()
        let started = Date()
        let task = Task {
            // Cancelled before the child is spawned: it must not be left running to completion.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], onLine: nil)
        }
        let result = try? await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertNotEqual(result?.exitCode, 0)
    }

    func testProcessRunnerKillsSilentProcessAfterIdleTimeout() async throws {
        let runner = ProcessRunner(idleTimeout: 0.5)
        let started = Date()
        let result = try await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], onLine: nil)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("no output for"), result.stderr)
    }

    func testProcessRunnerIdleTimeoutResetsOnOutput() async throws {
        let runner = ProcessRunner(idleTimeout: 0.8)
        let result = try await runner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "for i in 1 2 3 4; do echo tick; sleep 0.4; done; echo done"], onLine: nil)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.hasSuffix("done\n"))
    }

    func testProcessRunnerSplitsCarriageReturnProgress() async throws {
        let runner = ProcessRunner()
        let collected = LineCollector()
        _ = try await runner.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '10%%\\r50%%\\r100%%\\n'"],
            onLine: { line in collected.append(line) })
        XCTAssertEqual(collected.lines, ["10%", "50%", "100%"])
    }
}

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] { lock.withLock { storage } }
    func append(_ s: String) { lock.withLock { storage.append(s) } }
}
