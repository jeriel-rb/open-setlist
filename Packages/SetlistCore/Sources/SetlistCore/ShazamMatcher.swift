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

    public func match(_ buffer: AVAudioPCMBuffer) async throws -> Hit? {
        let generator = SHSignatureGenerator()
        try generator.append(buffer, at: nil)
        let signature = try generator.signature()

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
