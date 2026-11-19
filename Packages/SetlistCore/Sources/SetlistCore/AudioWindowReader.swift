import AVFoundation
import Foundation

/// Reads windows of an audio file as 44.1 kHz mono Float32 buffers, the format ShazamKit expects.
public struct AudioWindowReader: Sendable {
    public enum Error: Swift.Error, Equatable {
        case startPastEnd(start: Double, duration: Double)
        case allocationFailed
        case conversionFailed(String)
    }

    public static let targetSampleRate: Double = 44_100
    public let fileURL: URL
    public let duration: Double
    private let sourceSampleRate: Double
    private let sourceLength: AVAudioFramePosition

    public init(fileURL: URL) throws {
        let file = try AVAudioFile(forReading: fileURL)
        self.fileURL = fileURL
        self.sourceSampleRate = file.processingFormat.sampleRate
        self.sourceLength = file.length
        self.duration = Double(file.length) / file.processingFormat.sampleRate
    }

    public static var targetFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false)!
    }

    /// `length` seconds from `start`, clamped to the end of the file.
    public func buffer(start: Double, length: Double) throws -> AVAudioPCMBuffer {
        guard start < duration else { throw Error.startPastEnd(start: start, duration: duration) }
        let file = try AVAudioFile(forReading: fileURL)
        let startFrame = AVAudioFramePosition(start * sourceSampleRate)
        let wanted = AVAudioFrameCount(min(length, duration - start) * sourceSampleRate)
        file.framePosition = startFrame

        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: wanted),
              let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: wanted) else {
            throw Error.allocationFailed
        }
        // AVAudioFile may return fewer frames than asked after a seek; keep reading until the window is full.
        while source.frameLength < wanted {
            try file.read(into: chunk, frameCount: wanted - source.frameLength)
            guard chunk.frameLength > 0 else { break }
            Self.append(chunk, to: source)
        }

        let target = Self.targetFormat
        if file.processingFormat.sampleRate == target.sampleRate,
           file.processingFormat.channelCount == 1,
           file.processingFormat.commonFormat == .pcmFormatFloat32 {
            return source
        }
        return try convert(source, to: target)
    }

    private static func append(_ chunk: AVAudioPCMBuffer, to buffer: AVAudioPCMBuffer) {
        let channels = Int(buffer.format.channelCount)
        let offset = Int(buffer.frameLength)
        let count = Int(chunk.frameLength)
        if let dst = buffer.floatChannelData, let src = chunk.floatChannelData {
            for ch in 0..<channels { dst[ch].advanced(by: offset).update(from: src[ch], count: count) }
        } else if let dst = buffer.int16ChannelData, let src = chunk.int16ChannelData {
            for ch in 0..<channels { dst[ch].advanced(by: offset).update(from: src[ch], count: count) }
        } else if let dst = buffer.int32ChannelData, let src = chunk.int32ChannelData {
            for ch in 0..<channels { dst[ch].advanced(by: offset).update(from: src[ch], count: count) }
        }
        buffer.frameLength += chunk.frameLength
    }

    private func convert(_ source: AVAudioPCMBuffer, to target: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: source.format, to: target) else {
            throw Error.conversionFailed("no converter from \(source.format) to \(target)")
        }
        let ratio = target.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw Error.allocationFailed
        }
        final class Once: @unchecked Sendable { var consumed = false }
        let once = Once()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if once.consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            once.consumed = true
            outStatus.pointee = .haveData
            return source
        }
        if status == .error || conversionError != nil {
            throw Error.conversionFailed(conversionError?.localizedDescription ?? "unknown")
        }
        return output
    }
}
