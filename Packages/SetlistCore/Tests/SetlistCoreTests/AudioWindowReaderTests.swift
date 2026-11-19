import AVFoundation
import XCTest
@testable import SetlistCore

final class AudioWindowReaderTests: XCTestCase {
    private var wav: URL!

    override func setUpWithError() throws {
        wav = FileManager.default.temporaryDirectory.appendingPathComponent("AudioWindowReaderTests-\(UUID().uuidString).wav")
        try TestAudio.writeSine(to: wav, seconds: 3, sampleRate: 44_100)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: wav)
    }

    func testReaderReportsDuration() throws {
        let reader = try AudioWindowReader(fileURL: wav)
        XCTAssertEqual(reader.duration, 3, accuracy: 0.001)
    }

    func testReaderBuffersFromGeneratedWav() throws {
        let reader = try AudioWindowReader(fileURL: wav)
        let full = try reader.buffer(start: 1, length: 1)
        XCTAssertEqual(full.frameLength, 44_100)
        XCTAssertEqual(full.format.sampleRate, 44_100)
        XCTAssertEqual(full.format.channelCount, 1)
        XCTAssertEqual(full.format.commonFormat, .pcmFormatFloat32)

        let clamped = try reader.buffer(start: 2.5, length: 1)
        XCTAssertEqual(clamped.frameLength, 22_050)
    }

    func testReaderConvertsStereo48kToMono44k() throws {
        let stereo = FileManager.default.temporaryDirectory.appendingPathComponent("stereo-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: stereo) }
        try TestAudio.writeSine(to: stereo, seconds: 2, sampleRate: 48_000, channels: 2)
        let reader = try AudioWindowReader(fileURL: stereo)
        let buffer = try reader.buffer(start: 0, length: 1)
        XCTAssertEqual(buffer.format.sampleRate, 44_100)
        XCTAssertEqual(buffer.format.channelCount, 1)
        XCTAssertEqual(Int(buffer.frameLength), 44_100, accuracy: 10)
    }

    func testReaderPastEndThrows() throws {
        let reader = try AudioWindowReader(fileURL: wav)
        XCTAssertThrowsError(try reader.buffer(start: 5, length: 1))
    }
}

enum TestAudio {
    /// Writes a 440 Hz sine WAV.
    static func writeSine(to url: URL, seconds: Double, sampleRate: Double, channels: AVAudioChannelCount = 1) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<Int(channels) {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                data[i] = Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate)) * 0.5
            }
        }
        try file.write(from: buffer)
    }
}
