import XCTest
@testable import SetlistCore

final class JobStoreTests: XCTestCase {
    private var root: URL!
    private var store: JobStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = JobStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSanitizeReplacesPathCharacters() {
        XCTAssertEqual(
            JobStore.sanitizeFileName("LOOΠΔ / ODD EYE CIRCLE - Sweet Crazy Love"),
            "LOOΠΔ - ODD EYE CIRCLE - Sweet Crazy Love")
        XCTAssertEqual(JobStore.sanitizeFileName(#"a:b*c?d"e<f>g|h\i"#), "a-b-c-d-e-f-g-h-i")
        XCTAssertEqual(JobStore.sanitizeFileName("   "), "untitled")
        XCTAssertEqual(JobStore.sanitizeFileName(String(repeating: "x", count: 300)).count, 150)
        XCTAssertEqual(JobStore.sanitizeFileName("  two   spaces  "), "two spaces")
    }

    func testFileStemFormat() {
        XCTAssertEqual(Track(index: 3, query: "XG / LEFT RIGHT").fileStem, "03 - XG - LEFT RIGHT")
        XCTAssertEqual(Track(index: 12, query: "https://youtu.be/abc").fileStem, "12 - %(title).120B")
    }

    func testDuplicateNameGetsSuffix() throws {
        var first = Job(name: "kpop rnb", kind: .pasteList, tracks: [])
        var second = Job(name: "kpop rnb", kind: .pasteList, tracks: [])
        let firstDir = try store.directory(for: &first)
        try store.save(first)
        let secondDir = try store.directory(for: &second)
        try store.save(second)
        XCTAssertEqual(firstDir.lastPathComponent, "kpop rnb")
        XCTAssertEqual(secondDir.lastPathComponent, "kpop rnb 2")
        // Asking again for the first job returns its existing folder.
        XCTAssertEqual(try store.directory(for: &first), firstDir)
        var third = Job(name: "kpop rnb", kind: .pasteList, tracks: [])
        XCTAssertEqual(try store.directory(for: &third).lastPathComponent, "kpop rnb 3")
    }

    func testSaveAndLoadAllNewestFirst() throws {
        var older = Job(name: "older", kind: .pasteList, tracks: [Track(index: 1, query: "A - B")])
        older.createdAt = Date(timeIntervalSince1970: 1_000)
        var newer = Job(name: "newer", kind: .youtubeSet, sourceURL: URL(string: "https://youtu.be/x"), tracks: [])
        newer.createdAt = Date(timeIntervalSince1970: 2_000)
        _ = try store.directory(for: &older)
        _ = try store.directory(for: &newer)
        try store.save(older)
        try store.save(newer)

        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.map(\.name), ["newer", "older"])
        XCTAssertEqual(loaded[1].tracks.first?.query, "A - B")
        XCTAssertEqual(loaded[0].sourceURL?.absoluteString, "https://youtu.be/x")
        XCTAssertEqual(loaded[0].directoryName, "newer")
    }

    func testLoadAllIgnoresFoldersWithoutJobFile() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("random"), withIntermediateDirectories: true)
        XCTAssertEqual(try store.loadAll(), [])
    }

    func testWriteTracklistAndFailed() throws {
        var a = Track(index: 1, query: "A - B", start: 0)
        a.status = .done
        var b = Track(index: 2, query: "C - D", start: 90)
        b.status = .failed
        var job = Job(name: "set", kind: .youtubeSet, tracks: [a, b])
        let dir = try store.directory(for: &job)
        try store.writeTracklist(job)
        try store.writeFailed(job)

        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("tracklist.txt"), encoding: .utf8),
                       "00:00 A - B\n01:30 C - D\n")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("failed.txt"), encoding: .utf8),
                       "C - D\n")

        job.tracks[1].status = .done
        try store.writeFailed(job)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("failed.txt").path))

        var plain = Job(name: "plain", kind: .pasteList, tracks: [Track(index: 1, query: "E - F")])
        let plainDir = try store.directory(for: &plain)
        try store.writeTracklist(plain)
        XCTAssertEqual(try String(contentsOf: plainDir.appendingPathComponent("tracklist.txt"), encoding: .utf8), "E - F\n")
    }
}
