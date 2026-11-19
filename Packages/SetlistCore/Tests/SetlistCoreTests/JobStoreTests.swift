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

    func testSanitizeLimitsBytesNotCharacters() {
        // 150 Hangul syllables are 450 UTF-8 bytes, over the 255-byte file name limit.
        let name = JobStore.sanitizeFileName(String(repeating: "허", count: 150))
        XCTAssertLessThanOrEqual(name.utf8.count, JobStore.maxFileNameBytes)
        XCTAssertFalse(name.isEmpty)
        XCTAssertTrue(name.allSatisfy { $0 == "허" }, "must cut on a character boundary")
    }

    func testSanitizeNeverYieldsDotNames() {
        XCTAssertEqual(JobStore.sanitizeFileName(".."), "untitled")
        XCTAssertEqual(JobStore.sanitizeFileName("."), "untitled")
        XCTAssertEqual(JobStore.sanitizeFileName(".hidden mix"), "hidden mix")
        XCTAssertEqual(JobStore.sanitizeFileName("Vol. 2"), "Vol. 2")
    }

    func testFileStemEscapesTemplatePercent() {
        // yt-dlp reads % in the output template as a field; a literal one must be doubled.
        XCTAssertEqual(Track(index: 1, query: "Crystal Waters - 100% Pure Love").fileStem, "01 - Crystal Waters - 100%% Pure Love")
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

    func testRenameMovesDirectoryAndSaves() throws {
        var job = Job(name: "old name", kind: .pasteList, tracks: [Track(index: 1, query: "A - B")])
        let oldDir = try store.directory(for: &job)
        try store.save(job)
        try "x".write(to: oldDir.appendingPathComponent("01 - A - B.mp3"), atomically: true, encoding: .utf8)

        try store.rename(&job, to: "  new name  ")

        XCTAssertEqual(job.name, "new name")
        XCTAssertEqual(job.directoryName, "new name")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path))
        let newDir = root.appendingPathComponent("new name")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDir.appendingPathComponent("01 - A - B.mp3").path))
        XCTAssertEqual(try store.loadAll().map(\.name), ["new name"])
    }

    func testRenameWithoutMovingThenSync() throws {
        var job = Job(name: "running", kind: .pasteList, tracks: [])
        let dir = try store.directory(for: &job)
        try store.save(job)
        try store.rename(&job, to: "renamed", moveFolder: false)
        XCTAssertEqual(job.name, "renamed")
        XCTAssertEqual(job.directoryName, "running")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(try store.loadAll().first?.name, "renamed")

        try store.syncDirectory(&job)
        XCTAssertEqual(job.directoryName, "renamed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed/job.json").path))
    }

    func testRenameToTakenNameGetsSuffix() throws {
        var other = Job(name: "taken", kind: .pasteList, tracks: [])
        _ = try store.directory(for: &other)
        try store.save(other)
        var job = Job(name: "mine", kind: .pasteList, tracks: [])
        _ = try store.directory(for: &job)
        try store.save(job)

        try store.rename(&job, to: "taken")
        XCTAssertEqual(job.directoryName, "taken 2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("taken 2/job.json").path))
    }

    func testRenameToSameOrEmptyNameIsNoOp() throws {
        var job = Job(name: "same", kind: .pasteList, tracks: [])
        let dir = try store.directory(for: &job)
        try store.save(job)
        try store.rename(&job, to: "same")
        try store.rename(&job, to: "   ")
        XCTAssertEqual(job.name, "same")
        XCTAssertEqual(try store.directory(for: &job), dir)
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
