import XCTest
@testable import SetlistCore

final class YtDlpUpdaterTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("YtDlpUpdaterTests-\(UUID().uuidString)")
        StubURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        StubURLProtocol.reset()
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testUpdateWritesExecutableFile() async throws {
        StubURLProtocol.respond { request in
            XCTAssertEqual(request.url, YtDlpUpdater.downloadURL)
            return (200, Data("#!/bin/sh\necho 2026.12.01\n".utf8))
        }
        let updater = YtDlpUpdater(session: session(), overrideDir: dir)
        let file = try await updater.update()
        XCTAssertEqual(file.path, dir.appendingPathComponent("yt-dlp").path)
        XCTAssertEqual(try Data(contentsOf: file), Data("#!/bin/sh\necho 2026.12.01\n".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(mode.intValue & 0o111, 0o111)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: file.path))
    }

    func testUpdateFailsOnHTTPError() async {
        StubURLProtocol.respond { _ in (404, Data()) }
        let updater = YtDlpUpdater(session: session(), overrideDir: dir)
        do {
            _ = try await updater.update()
            XCTFail("expected throw")
        } catch let error as YtDlpUpdater.Error {
            XCTAssertEqual(error, .httpStatus(404))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("yt-dlp").path))
    }

    func testUpdatedBinaryWinsInLocator() async throws {
        StubURLProtocol.respond { _ in (200, Data("#!/bin/sh\necho updated\n".utf8)) }
        let updater = YtDlpUpdater(session: session(), overrideDir: dir)
        _ = try await updater.update()
        let locator = ToolLocator(overrideDir: dir, bundleBinDir: try TestTools.locator().bundleBinDir, searchPaths: [])
        let result = try await ProcessRunner().run(try locator.url(for: .ytDlp), arguments: [], onLine: nil)
        XCTAssertEqual(result.stdout, "updated\n")
    }

    func testInstalledVersionRunsVersionFlag() async throws {
        let runner = FakeRunner(results: [.ok("2026.10.26\n")])
        let updater = YtDlpUpdater(session: session(), overrideDir: dir)
        let version = await updater.installedVersion(runner: runner, locator: try TestTools.locator())
        XCTAssertEqual(version, "2026.10.26")
        XCTAssertEqual(runner.calls.first?.arguments, ["--version"])
    }
}

/// Serves canned HTTP responses to any URLSession configured with it.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    static func respond(_ h: @escaping @Sendable (URLRequest) -> (Int, Data)) { handler = h }
    static func reset() { handler = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
