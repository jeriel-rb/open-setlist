import AVFoundation
import XCTest
@testable import SetlistCore

final class SetIdentifierTests: XCTestCase {
    private let a = Hit(shazamID: "A", title: "Right Now", artist: "NewJeans", confidence: nil)
    private let b = Hit(shazamID: "B", title: "LEFT RIGHT (R&B Remix)", artist: "XG", confidence: nil)
    private var wav: URL!

    override func tearDownWithError() throws {
        if let wav { try? FileManager.default.removeItem(at: wav) }
    }

    private func makeWav(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SetIdentifierTests-\(UUID().uuidString).wav")
        try TestAudio.writeSine(to: url, seconds: seconds, sampleRate: 44_100)
        wav = url
        return url
    }

    func testUsesDescriptionTracklistBeforeShazam() {
        let info = MixInfo(title: "Mix", description: "00:00 A - B\n01:30 C - D\n03:00 E - F", duration: 300, comments: ["00:00 X - Y\n01:00 Z - W\n02:00 Q - R"])
        let found = SetIdentifier.tracksFromText(info)
        XCTAssertEqual(found?.source, .description)
        XCTAssertEqual(found?.tracks.map(\.query), ["A - B", "C - D", "E - F"])
        XCTAssertEqual(found?.tracks.map(\.start), [0, 90, 180])
        XCTAssertEqual(found?.tracks.map(\.index), [1, 2, 3])
        XCTAssertTrue(found?.tracks.allSatisfy { $0.confidence == .fromText } ?? false)
    }

    func testFallsBackToCommentsTracklist() {
        let info = MixInfo(title: "Mix", description: "no list here", duration: 300,
                           comments: ["fire 🔥", "00:00 X - Y\n01:00 Z - W\n02:00 Q - R"])
        let found = SetIdentifier.tracksFromText(info)
        XCTAssertEqual(found?.source, .comments)
        XCTAssertEqual(found?.tracks.map(\.query), ["X - Y", "Z - W", "Q - R"])
    }

    func testNoTracklistInTextReturnsNil() {
        let info = MixInfo(title: "Mix", description: "00:00 only one", duration: 300, comments: ["two 01:00 lines", "nope"])
        XCTAssertNil(SetIdentifier.tracksFromText(info))
    }

    func testShortMixYieldsEmpty() async throws {
        let matcher = FakeMatcher(hits: [a])
        let identifier = SetIdentifier(matcher: matcher, delay: .zero)
        let tracks = try await identifier.identify(wav: try makeWav(seconds: 10)) { _ in }
        XCTAssertEqual(tracks, [])
        XCTAssertEqual(matcher.callCount, 0)
    }

    func testIdentifyCallsMatcherPerSliceAndMerges() async throws {
        let matcher = FakeMatcher(hits: [a, a, b])
        let identifier = SetIdentifier(matcher: matcher, delay: .zero)
        let progress = LineCollector()
        let tracks = try await identifier.identify(wav: try makeWav(seconds: 90)) { progress.append(String($0)) }
        XCTAssertEqual(matcher.callCount, 3)
        XCTAssertEqual(tracks.map(\.hit.shazamID), ["A", "B"])
        XCTAssertEqual(tracks[0].start, 0)
        XCTAssertEqual(tracks[1].start, 60)
        XCTAssertEqual(tracks[1].end, 90, accuracy: 0.01)
        XCTAssertEqual(progress.lines.last, "1.0")
        // Each window is 12 s starting 9 s into its 30 s slice.
        XCTAssertEqual(matcher.frameLengths, [12 * 44_100, 12 * 44_100, 12 * 44_100])
    }

    func testIdentifyToleratesMatcherErrorsAsNoMatch() async throws {
        let matcher = FakeMatcher(hits: [a, nil, a], failOn: [1])
        let identifier = SetIdentifier(matcher: matcher, delay: .zero)
        let tracks = try await identifier.identify(wav: try makeWav(seconds: 90)) { _ in }
        XCTAssertEqual(tracks.map(\.hit.shazamID), ["A"])
        XCTAssertEqual(matcher.callCount, 3)
    }

    func testIdentifyThrowsWhenEverySliceErrors() async throws {
        let matcher = FakeMatcher(hits: [a, a, a], failOn: [0, 1, 2])
        let identifier = SetIdentifier(matcher: matcher, delay: .zero)
        do {
            _ = try await identifier.identify(wav: try makeWav(seconds: 90)) { _ in }
            XCTFail("expected throw")
        } catch let error as SetIdentifier.Error {
            guard case let .everySliceFailed(underlying) = error else { return XCTFail("wrong case \(error)") }
            XCTAssertEqual((underlying as? URLError)?.code, .networkConnectionLost)
            XCTAssertTrue(error.localizedDescription.contains("ShazamKit"))
        }
    }

    func testRemixTitlesAreHighConfidence() {
        let tracks = SetIdentifier.toTracks([
            IdentifiedTrack(start: 0, end: 60, hit: a),
            IdentifiedTrack(start: 60, end: 90, hit: b),
        ])
        XCTAssertEqual(tracks.map(\.confidence), [.medium, .high])
        XCTAssertEqual(tracks.map(\.index), [1, 2])
        XCTAssertEqual(tracks.map(\.start), [0, 60])
        XCTAssertEqual(tracks[1].query, "XG - LEFT RIGHT (R&B Remix)")
    }

    func testLiveShazamIdentifiesKnownSong() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SETLIST_LIVE"] == "1", "set SETLIST_LIVE=1 to run")
        let repoBin = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bin")
        let locator = ToolLocator(overrideDir: nil, bundleBinDir: repoBin, searchPaths: [])
        let fetcher = MixFetcher(runner: ProcessRunner(), locator: locator)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }
        try await fetcher.fetchAudio(url: URL(string: "ytsearch1:XG - LEFT RIGHT official")!, to: out, onLine: nil)
        let identifier = SetIdentifier(matcher: ShazamMatcher(), delay: .zero)
        let tracks = try await identifier.identify(wav: out) { _ in }
        XCTAssertTrue(tracks.contains { $0.hit.artist.localizedCaseInsensitiveContains("XG") }, "got \(tracks)")
    }
}

final class FakeMatcher: SliceMatching, @unchecked Sendable {
    private let lock = NSLock()
    private var hits: [Hit?]
    private let failOn: Set<Int>
    private(set) var callCount = 0
    private(set) var frameLengths: [AVAudioFrameCount] = []

    init(hits: [Hit?], failOn: Set<Int> = []) {
        self.hits = hits
        self.failOn = failOn
    }

    func match(_ buffer: AVAudioPCMBuffer) async throws -> Hit? {
        let frames = buffer.frameLength
        let (index, hit): (Int, Hit?) = lock.withLock {
            let index = callCount
            callCount += 1
            frameLengths.append(frames)
            return (index, index < hits.count ? hits[index] : nil)
        }
        if failOn.contains(index) { throw URLError(.networkConnectionLost) }
        return hit
    }
}
