import AVFoundation
import XCTest
@testable import SetlistCore

final class AudioAnalyzerTests: XCTestCase {
    private var files: [URL] = []

    override func tearDownWithError() throws {
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func write(seconds: Double, sampleRate: Double = 44_100, _ sample: (Double) -> Float) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AudioAnalyzerTests-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = sample(Double(i) / sampleRate)
        }
        try file.write(from: buffer)
        files.append(url)
        return url
    }

    private func chord(_ midi: [Int]) -> (Double) -> Float {
        let freqs = midi.map { 440 * pow(2, Double($0 - 69) / 12) }
        return { t in
            var v = 0.0
            for f in freqs { v += sin(2 * .pi * f * t) + 0.3 * sin(2 * .pi * 2 * f * t) }
            return Float(v / Double(freqs.count) * 0.4)
        }
    }

    private func clicks(bpm: Double, under tone: ((Double) -> Float)? = nil) -> (Double) -> Float {
        let period = 60 / bpm
        return { t in
            let phase = t.truncatingRemainder(dividingBy: period)
            let click: Float = phase < 0.02 ? Float(sin(2 * .pi * 1000 * t)) * Float(1 - phase / 0.02) : 0
            return click * 0.8 + (tone?(t) ?? 0) * 0.2
        }
    }

    func testCamelotMapping() {
        XCTAssertEqual(AudioAnalyzer.camelot(pitchClass: 0, minor: false), "8B")   // C major
        XCTAssertEqual(AudioAnalyzer.camelot(pitchClass: 9, minor: true), "8A")    // A minor
        XCTAssertEqual(AudioAnalyzer.camelot(pitchClass: 7, minor: false), "9B")   // G major
        XCTAssertEqual(AudioAnalyzer.camelot(pitchClass: 4, minor: true), "9A")    // E minor
        XCTAssertEqual(AudioAnalyzer.camelot(pitchClass: 5, minor: false), "7B")   // F major
        XCTAssertEqual(AudioAnalyzer.camelot(pitchClass: 11, minor: false), "1B")  // B major
        XCTAssertEqual(AudioAnalyzer.camelot(pitchClass: 8, minor: true), "1A")    // G# minor
        XCTAssertEqual(AudioAnalyzer.keyName(pitchClass: 9, minor: true), "A minor")
        XCTAssertEqual(AudioAnalyzer.keyName(pitchClass: 1, minor: false), "C# major")
        XCTAssertEqual(AudioAnalyzer.id3Key(pitchClass: 9, minor: true), "Am")
        XCTAssertEqual(AudioAnalyzer.id3Key(pitchClass: 6, minor: false), "F#")
    }

    func testDetectsKeyOfMajorTriad() throws {
        let file = try write(seconds: 8, chord([60, 64, 67, 72]))  // C E G C
        let result = try AudioAnalyzer().analyze(file: file)
        XCTAssertEqual(result.camelot, "8B")
        XCTAssertEqual(result.keyName, "C major")
    }

    func testDetectsKeyOfMinorTriad() throws {
        let file = try write(seconds: 8, chord([57, 60, 64, 69]))  // A C E A
        let result = try AudioAnalyzer().analyze(file: file)
        XCTAssertEqual(result.camelot, "8A")
        XCTAssertEqual(result.keyName, "A minor")
    }

    func testDetectsTempoOfClickTrack() throws {
        let file = try write(seconds: 20, clicks(bpm: 120, under: chord([62, 66, 69])))
        let result = try AudioAnalyzer().analyze(file: file)
        XCTAssertEqual(Double(result.bpm), 120, accuracy: 2)
    }

    func testDetectsSlowerTempo() throws {
        let file = try write(seconds: 20, clicks(bpm: 95))
        let result = try AudioAnalyzer().analyze(file: file)
        XCTAssertEqual(Double(result.bpm), 95, accuracy: 2)
    }

    func testHandlesStereo48kInput() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stereo-\(UUID().uuidString).wav")
        files.append(url)
        try TestAudio.writeSine(to: url, seconds: 6, sampleRate: 48_000, channels: 2)  // 440 Hz = A
        let result = try AudioAnalyzer().analyze(file: url)
        XCTAssertTrue(result.keyName.hasPrefix("A "), result.keyName)
        XCTAssertGreaterThan(result.bpm, 0)
    }

    func testLiveAnalyzeRealMP3() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SETLIST_LIVE"] == "1", "set SETLIST_LIVE=1 to run")
        let mp3 = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/mp3grab/kpop-rnb/02 - XG - LEFT RIGHT.mp3")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: mp3.path), "no sample mp3")
        let started = Date()
        let result = try AudioAnalyzer().analyze(file: mp3)
        print("LIVE analysis:", result, "in", Date().timeIntervalSince(started), "s")
        XCTAssertTrue((60...200).contains(result.bpm))
        XCTAssertFalse(result.camelot.isEmpty)
    }

    func testTooShortFileThrows() throws {
        let file = try write(seconds: 0.5, chord([60]))
        XCTAssertThrowsError(try AudioAnalyzer().analyze(file: file))
    }
}
