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
}
