import XCTest
@testable import SetlistCore

final class JobTests: XCTestCase {
    private func job(_ statuses: [TrackStatus]) -> Job {
        var tracks = statuses.enumerated().map { Track(index: $0.offset + 1, query: "T\($0.offset)") }
        for i in tracks.indices {
            tracks[i].status = statuses[i]
            tracks[i].activity = "Downloading 10%"
        }
        return Job(name: "j", kind: .pasteList, tracks: tracks)
    }

    func testMarkingInterruptedCancelsActiveTracksOnly() {
        let j = job([.done, .searching, .downloading, .analyzing, .pending, .failed, .skipped])
        let marked = j.markingInterrupted()
        XCTAssertEqual(marked.tracks.map(\.status), [.done, .cancelled, .cancelled, .cancelled, .cancelled, .failed, .skipped])
        XCTAssertEqual(marked.tracks[1].note, Job.interruptedNote)
        XCTAssertNil(marked.tracks[1].activity)
        XCTAssertNil(marked.tracks[0].note)
        XCTAssertTrue(j.hasActiveTracks)
        XCTAssertFalse(marked.hasActiveTracks)
    }

    func testResettingForRetryRequeuesFailedAndCancelled() {
        var j = job([.done, .failed, .cancelled, .skipped])
        j.tracks[1].note = "boom"
        let reset = j.resettingForRetry()
        XCTAssertEqual(reset.tracks.map(\.status), [.done, .pending, .pending, .skipped])
        XCTAssertNil(reset.tracks[1].note)
        XCTAssertNil(reset.tracks[1].activity)
        XCTAssertEqual(j.retryableCount, 2)
        XCTAssertEqual(reset.retryableCount, 0)
    }

    func testAppendingContinuesTheNumberingAndLeavesOldTracksAlone() {
        let j = job([.done, .failed])
        let (added, count) = j.appending(["https://soundcloud.com/a/b", "New - Song"])
        XCTAssertEqual(count, 2)
        XCTAssertEqual(added.tracks.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(added.tracks.map(\.query), ["T0", "T1", "https://soundcloud.com/a/b", "New - Song"])
        XCTAssertEqual(added.tracks.map(\.status), [.done, .failed, .pending, .pending])
        XCTAssertEqual(added.id, j.id)
    }

    func testAppendingNumbersAfterTheHighestIndexNotTheCount() {
        var j = job([.done, .done])
        j.tracks[1].index = 7
        XCTAssertEqual(j.appending(["X - Y"]).job.tracks.last?.index, 8)
    }

    func testAppendingSkipsSongsAlreadyInTheJobAndRepeats() {
        let j = job([.done, .done])
        let (added, count) = j.appending([" t0 ", "New - Song", "new - song", "  "])
        XCTAssertEqual(count, 1)
        XCTAssertEqual(added.tracks.map(\.query), ["T0", "T1", "New - Song"])
        XCTAssertEqual(j.appending(["T1"]).added, 0)
    }

    func testSecondsForBarsFollowTheTempoAndCorrectHalfAndDoubleReadings() {
        var track = Track(index: 1, query: "A - B")
        XCTAssertEqual(track.seconds(forBars: 8), 15, accuracy: 0.001)   // no tempo: 128 BPM
        track.bpm = 120
        XCTAssertEqual(track.seconds(forBars: 8), 16, accuracy: 0.001)
        XCTAssertEqual(track.seconds(forBars: 1), 2, accuracy: 0.001)
        track.bpm = 65                                                    // really 130
        XCTAssertEqual(track.seconds(forBars: 8), 32 * 60 / 130.0, accuracy: 0.001)
        track.bpm = 195                                                   // really 97.5
        XCTAssertEqual(track.seconds(forBars: 8), 32 * 60 / 97.5, accuracy: 0.001)
    }

    func testALinksSourceIsKnownBeforeItIsDownloaded() {
        var link = Track(index: 1, query: "https://soundcloud.com/a/b")
        XCTAssertEqual(link.knownSource, "https://soundcloud.com/a/b")
        link.sourceURL = "https://soundcloud.com/a/b-final"
        XCTAssertEqual(link.knownSource, "https://soundcloud.com/a/b-final")
        XCTAssertNil(Track(index: 1, query: "A - B").knownSource)
    }

    func testAppendingTracksKeepsTheirSongNames() {
        var named = Track(index: 9, query: "https://soundcloud.com/a/b")
        named.songName = "A - B"
        let added = job([.done]).appending(tracks: [named]).job
        XCTAssertEqual(added.tracks.last?.index, 2)
        XCTAssertEqual(added.tracks.last?.songName, "A - B")
        XCTAssertEqual(added.tracks.last?.displayName, "A - B")
        XCTAssertEqual(added.tracks.first?.displayName, "T0")
    }
}
