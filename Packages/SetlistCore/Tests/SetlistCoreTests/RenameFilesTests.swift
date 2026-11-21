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

    func testALinkWhoseNameWasClearedIsStillNamedAfterItsFile() throws {
        var (job, dir) = try makeJob([("https://youtu.be/abc", "01 - Tyga - Taste (Official Video).mp3")])
        // The name field of a link was emptied before the download: that is no name, not a song called "".
        job.tracks[0].songName = " "
        var format = FileNameFormat.standard
        format.order = [.title, .artist, .number]
        try store.renameFiles(of: &job, to: format)
        XCTAssertEqual(try files(in: dir), ["Taste (Official Video) - Tyga - 01.mp3"])
        XCTAssertEqual(job.tracks[0].songName, "Tyga - Taste (Official Video)")
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

    // MARK: One song: rename, delete, order in Finder

    func testRenamingATypedSongRenamesItsFileInTheJobsFormat() throws {
        var (job, dir) = try makeJob([("XG - LEFT RIGHT", "01 - XG - LEFT RIGHT.mp3"), ("A - B", "02 - A - B.mp3")])
        try store.renameTrack(job.tracks[0].id, in: &job, to: "  XG - Left Right (Remix) ")
        XCTAssertEqual(try files(in: dir), ["01 - XG - Left Right (Remix).mp3", "02 - A - B.mp3"])
        XCTAssertEqual(job.tracks[0].query, "XG - Left Right (Remix)")
        XCTAssertEqual(URL(fileURLWithPath: job.tracks[0].outputPath!).lastPathComponent, "01 - XG - Left Right (Remix).mp3")
        XCTAssertEqual(try store.loadAll().first?.tracks.first?.query, "XG - Left Right (Remix)")
    }

    func testRenamingALinkKeepsItsAddressAndFollowsTheFormat() throws {
        var (job, dir) = try makeJob([("https://soundcloud.com/a/b", "B - A.mp3")])
        job.fileNameFormat = .preferred
        try store.renameTrack(job.tracks[0].id, in: &job, to: "Artist - Song")
        XCTAssertEqual(try files(in: dir), ["Song - Artist.mp3"])
        XCTAssertEqual(job.tracks[0].query, "https://soundcloud.com/a/b")
        XCTAssertEqual(job.tracks[0].displayName, "Artist - Song")
    }

    func testRenamingRefusesAnEmptyNameAndANameAnotherFileHas() throws {
        var (job, dir) = try makeJob([("A - B", "01 - A - B.mp3"), ("C - D", "02 - C - D.mp3")])
        job.fileNameFormat = .preferred
        try FileManager.default.moveItem(at: dir.appendingPathComponent("01 - A - B.mp3"), to: dir.appendingPathComponent("B - A.mp3"))
        try FileManager.default.moveItem(at: dir.appendingPathComponent("02 - C - D.mp3"), to: dir.appendingPathComponent("D - C.mp3"))
        job.tracks[0].outputPath = "B - A.mp3"
        job.tracks[1].outputPath = "D - C.mp3"
        XCTAssertThrowsError(try store.renameTrack(job.tracks[0].id, in: &job, to: "  ")) {
            XCTAssertEqual($0 as? JobStore.TrackFileError, .emptyName)
        }
        XCTAssertThrowsError(try store.renameTrack(job.tracks[0].id, in: &job, to: "C - D")) {
            XCTAssertEqual($0 as? JobStore.TrackFileError, .nameTaken("D - C.mp3"))
        }
        XCTAssertEqual(try files(in: dir), ["B - A.mp3", "D - C.mp3"])
        XCTAssertEqual(job.tracks[0].query, "A - B")
    }

    func testDeletingASongDiscardsItsFileAndKeepsTheOthersNumbers() throws {
        var (job, dir) = try makeJob([("A - B", "01 - A - B.mp3"), ("C - D", "02 - C - D.mp3"), ("E - F", nil)])
        var discarded: [String] = []
        try store.deleteTrack(job.tracks[0].id, from: &job) { file in
            discarded.append(file.lastPathComponent)
            try FileManager.default.removeItem(at: file)
        }
        // A song that was never downloaded has no file to discard.
        try store.deleteTrack(job.tracks[1].id, from: &job) { _ in XCTFail("nothing to discard") }
        XCTAssertEqual(discarded, ["01 - A - B.mp3"])
        XCTAssertEqual(try files(in: dir), ["02 - C - D.mp3"])
        XCTAssertEqual(job.tracks.map(\.index), [2])
        XCTAssertEqual(try store.loadAll().first?.tracks.map(\.query), ["C - D"])
    }

    func testStampingDatesTheFilesInListOrder() throws {
        let (job, dir) = try makeJob([("Zed - Last Alphabetically", "Zed.mp3"), ("Gone - Missing", nil), ("Abe - First Alphabetically", "Abe.mp3")])
        XCTAssertEqual(store.stampListOrder(of: job), 2)
        let created = try ["Zed.mp3", "Abe.mp3"].map {
            try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($0).path)[.creationDate] as! Date
        }
        XCTAssertEqual(created[0].timeIntervalSince(job.createdAt), 0, accuracy: 1)
        XCTAssertEqual(created[1].timeIntervalSince(created[0]), 2, accuracy: 0.01)
    }
}
