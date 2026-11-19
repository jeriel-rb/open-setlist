import AVFoundation
import Foundation
import ShazamKit

/// Anything that can name the song in a short audio buffer.
public protocol SliceMatching: Sendable {
    func match(_ buffer: AVAudioPCMBuffer) async throws -> Hit?
}

/// ShazamKit against Shazam's catalog. Requires the ShazamKit app service on the signing App ID.
public struct ShazamMatcher: SliceMatching {
    public init() {}

    /// Asks Shazam about three seconds of a plain tone. The answer is always "no match"; what matters is
    /// whether the service answers at all. Throws what a real identification would throw (not signed for
    /// ShazamKit, offline), so that can be found out before a long download instead of after it.
    public static func preflight() async throws {
        let format = AudioWindowReader.targetFormat
        let frames = AVAudioFrameCount(format.sampleRate * 3)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            samples[i] = Float(sin(2 * Double.pi * 440 * Double(i) / format.sampleRate)) * 0.3
        }
        _ = try await ShazamMatcher().match(buffer)
    }

    public func match(_ buffer: AVAudioPCMBuffer) async throws -> Hit? {
        let generator = SHSignatureGenerator()
        try generator.append(buffer, at: nil)
        let signature = generator.signature()

        let session = SHSession()
        let result = await session.result(from: signature)
        switch result {
        case let .match(match):
            guard let item = match.mediaItems.first, let id = item.shazamID else { return nil }
            var confidence: Float?
            if #available(macOS 15.4, *) { confidence = item.confidence }
            return Hit(shazamID: id, title: item.title ?? "Unknown title", artist: item.artist ?? "Unknown artist", confidence: confidence)
        case .noMatch:
            return nil
        case let .error(error, _):
            throw error
        }
    }
}
