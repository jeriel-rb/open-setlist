import XCTest
@testable import SetlistCore

final class RenameFilesTests: XCTestCase {
    private var root: URL!
    private var store: JobStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RenameFilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = JobStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A saved job whose tracks are done, with a file on disk for every given name.
    private func makeJob(_ items: [(query: String, file: String?)]) throws -> (Job, URL) {
        var job = Job(name: "set", kind: .pasteList, tracks: items.enumerated().map { Track(index: $0 + 1, query: $1.query) })
        let dir = try store.directory(for: &job)
        for (i, item) in items.enumerated() {
            guard let file = item.file else { continue }
            let url = dir.appendingPathComponent(file)
            try Data("audio \(i)".utf8).write(to: url)
            job.tracks[i].status = .done
            // Deliberately a stale folder: files are found by name in the job's current folder.
            job.tracks[i].outputPath = "/somewhere/else/" + file
        }
        try store.save(job)
        return (job, dir)
    }

    private func files(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".mp3") }.sorted()
    }

    func testRenamesToANewOrderWithoutNumbers() throws {
        var (job, dir) = try makeJob([("XG - LEFT RIGHT", "01 - XG - LEFT RIGHT.mp3"), ("KATSEYE - Gabriela", "02 - KATSEYE - Gabriela.mp3")])
        var format = FileNameFormat.standard
        format.order = [.title, .artist, .number]
        format.included = [.title, .artist]
        XCTAssertEqual(try store.renameFiles(of: &job, to: format), 2)
        XCTAssertEqual(try files(in: dir), ["Gabriela - KATSEYE.mp3", "LEFT RIGHT - XG.mp3"])
        XCTAssertEqual(job.tracks[0].outputPath, dir.appendingPathComponent("LEFT RIGHT - XG.mp3").path)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("LEFT RIGHT - XG.mp3"), encoding: .utf8), "audio 0")
        let saved = try store.loadAll().first
        XCTAssertEqual(saved?.fileNameFormat, format)
        XCTAssertEqual(saved?.tracks.map(\.outputPath), job.tracks.map(\.outputPath))
    }

    func testRenamingTwiceUsesTheFormatTheJobRemembers() throws {
        var (job, dir) = try makeJob([("XG - LEFT RIGHT", "01 - XG - LEFT RIGHT.mp3")])
        var titleOnly = FileNameFormat.standard
        titleOnly.included = [.title]
        try store.renameFiles(of: &job, to: titleOnly)
        try store.renameFiles(of: &job, to: .standard)
        XCTAssertEqual(try files(in: dir), ["01 - XG - LEFT RIGHT.mp3"])
    }

    func testLinkTracksKeepTheVideoTitleAndCanBeReordered() throws {
        var (job, dir) = try makeJob([("https://youtu.be/abc", "01 - Tyga - Taste (Official Video).mp3")])
        var format = FileNameFormat.standard
        format.order = [.title, .artist, .number]
        try store.renameFiles(of: &job, to: format)
        XCTAssertEqual(try files(in: dir), ["Taste (Official Video) - Tyga - 01.mp3"])
        // And back again: the title is recovered from the name the previous format produced.
        try store.renameFiles(of: &job, to: .standard)
        XCTAssertEqual(try files(in: dir), ["01 - Tyga - Taste (Official Video).mp3"])
    }

    func testSameNameGetsACounterInsteadOfOverwriting() throws {
        var (job, dir) = try makeJob([("XG - LEFT RIGHT", "01 - XG - LEFT RIGHT.mp3"), ("XG - LEFT RIGHT", "02 - XG - LEFT RIGHT.mp3")])
        var format = FileNameFormat.standard
        format.included = [.artist, .title]
        try store.renameFiles(of: &job, to: format)
        XCTAssertEqual(try files(in: dir), ["XG - LEFT RIGHT (2).mp3", "XG - LEFT RIGHT.mp3"])
    }

    func testAFileThatIsNotPartOfTheJobIsNeverOverwritten() throws {
        var (job, dir) = try makeJob([("XG - LEFT RIGHT", "01 - XG - LEFT RIGHT.mp3")])
        try Data("mine".utf8).write(to: dir.appendingPathComponent("XG - LEFT RIGHT.mp3"))
        var format = FileNameFormat.standard
        format.included = [.artist, .title]
        try store.renameFiles(of: &job, to: format)
        XCTAssertEqual(try files(in: dir), ["XG - LEFT RIGHT (2).mp3", "XG - LEFT RIGHT.mp3"])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("XG - LEFT RIGHT.mp3"), encoding: .utf8), "mine")
    }

    func testNumbersCanShiftOntoEachOthersNames() throws {
        // 1 digit → 2 digits is harmless; the hard case is names that swap. Simulate with indexes changed after download.
        var (job, dir) = try makeJob([("A - One", "02 - A - One.mp3"), ("B - Two", "01 - B - Two.mp3")])
        try store.renameFiles(of: &job, to: .standard)
        XCTAssertEqual(try files(in: dir), ["01 - A - One.mp3", "02 - B - Two.mp3"])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("01 - A - One.mp3"), encoding: .utf8), "audio 0")
    }

    func testMissingAndUnfinishedTracksAreSkipped() throws {
        var (job, dir) = try makeJob([("XG - LEFT RIGHT", "01 - XG - LEFT RIGHT.mp3"), ("Gone - Song", nil)])
        job.tracks[1].status = .done
        job.tracks[1].outputPath = "/nowhere/02 - Gone - Song.mp3"
        var format = FileNameFormat.standard
        format.included = [.title]
        XCTAssertEqual(try store.renameFiles(of: &job, to: format), 1)
        XCTAssertEqual(try files(in: dir), ["LEFT RIGHT.mp3"])
        XCTAssertEqual(job.tracks[1].outputPath, "/nowhere/02 - Gone - Song.mp3")
    }
}
