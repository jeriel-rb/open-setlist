import XCTest
@testable import SetlistCore

final class MatchMergerTests: XCTestCase {
    private let a = Hit(shazamID: "A", title: "Right Now", artist: "NewJeans", confidence: 0.9)
    private let b = Hit(shazamID: "B", title: "LEFT RIGHT", artist: "XG", confidence: 0.8)

    private func slices(_ hits: [Hit?], every step: Double = 30) -> [SliceMatch] {
        hits.enumerated().map { SliceMatch(start: Double($0.offset) * step, hit: $0.element) }
    }

    func testMergeConsecutive() {
        let tracks = MatchMerger.merge(slices([a, a, a, b, b]), totalDuration: 150)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].start, 0)
        XCTAssertEqual(tracks[0].end, 90)
        XCTAssertEqual(tracks[0].hit, a)
        XCTAssertEqual(tracks[0].query, "NewJeans - Right Now")
        XCTAssertEqual(tracks[1].start, 90)
        XCTAssertEqual(tracks[1].end, 150)
        XCTAssertEqual(tracks[1].hit, b)
    }

    func testNilGapWithinToleranceKeepsRun() {
        let tracks = MatchMerger.merge(slices([a, nil, a, nil, nil, b]), totalDuration: 180)
        XCTAssertEqual(tracks.map(\.hit.shazamID), ["A", "B"])
        XCTAssertEqual(tracks[0].start, 0)
        XCTAssertEqual(tracks[1].start, 150)
    }

    func testSingletonBetweenSameTrackIsDropped() {
        let tracks = MatchMerger.merge(slices([a, a, b, a, a]), totalDuration: 150)
        XCTAssertEqual(tracks.map(\.hit.shazamID), ["A"])
        XCTAssertEqual(tracks[0].start, 0)
        XCTAssertEqual(tracks[0].end, 150)
    }

    func testSingletonBetweenDifferentTracksIsKept() {
        let c = Hit(shazamID: "C", title: "Gabriela", artist: "KATSEYE", confidence: nil)
        let tracks = MatchMerger.merge(slices([a, a, b, c, c]), totalDuration: 150)
        XCTAssertEqual(tracks.map(\.hit.shazamID), ["A", "B", "C"])
    }

    func testLeadingNilsShiftFirstStart() {
        let tracks = MatchMerger.merge(slices([nil, nil, a, a]), totalDuration: 120)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].start, 60)
    }

    func testAllNilYieldsEmpty() {
        XCTAssertEqual(MatchMerger.merge(slices([nil, nil, nil]), totalDuration: 90), [])
        XCTAssertEqual(MatchMerger.merge([], totalDuration: 0), [])
    }

    func testIdentifiedTrackQueryUsesArtistDashTitle() {
        let track = IdentifiedTrack(start: 0, end: 30, hit: b)
        XCTAssertEqual(track.query, "XG - LEFT RIGHT")
    }
}
