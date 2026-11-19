import Foundation

/// A raw Chromaprint fingerprint: one 32-bit value per ~0.124 s of audio.
public struct Fingerprint: Equatable, Sendable {
    public let values: [UInt32]

    public init(values: [UInt32]) {
        self.values = values
    }
}

public enum FingerprintCompare {
    /// How alike two recordings are, 0…1: the best match over every alignment of one against the other,
    /// where a match is the share of equal bits across the overlap. Unrelated audio scores about 0.5.
    /// Alignments overlapping by fewer than `minOverlap` values are too short to trust and are skipped,
    /// so two fingerprints that can never overlap that much score 0.
    public static func similarity(_ a: Fingerprint, _ b: Fingerprint, minOverlap: Int = 60) -> Double {
        let x = a.values, y = b.values
        guard min(x.count, y.count) >= minOverlap else { return 0 }
        var best = 0.0
        // offset is where y[0] sits relative to x[0].
        for offset in (minOverlap - y.count)...(x.count - minOverlap) {
            let xStart = max(0, offset), yStart = max(0, -offset)
            let overlap = min(x.count - xStart, y.count - yStart)
            var differing = 0
            for i in 0..<overlap {
                differing += (x[xStart + i] ^ y[yStart + i]).nonzeroBitCount
            }
            best = max(best, 1 - Double(differing) / Double(overlap * 32))
        }
        return best
    }
}

/// Fingerprints audio files with Chromaprint's `fpcalc`.
public struct Fingerprinter: Sendable {
    public let runner: CommandRunning
    public let locator: ToolLocator

    public init(runner: CommandRunning, locator: ToolLocator) {
        self.runner = runner
        self.locator = locator
    }

    public static func arguments(file: URL, maxLength: Double) -> [String] {
        ["-raw", "-json", "-length", String(Int(maxLength)), file.path]
    }

    /// Fingerprint of the first `maxLength` seconds of `file`.
    public func fingerprint(file: URL, maxLength: Double = 120) async throws -> Fingerprint {
        struct Output: Decodable { let fingerprint: [UInt32] }
        let fpcalc = try locator.url(for: .fpcalc)
        let result = try await runner.run(fpcalc, arguments: Self.arguments(file: file, maxLength: maxLength), onLine: nil)
        guard result.exitCode == 0 else {
            throw ToolError.failed(.fpcalc, exitCode: result.exitCode, stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Fingerprint(values: try JSONDecoder().decode(Output.self, from: Data(result.stdout.utf8)).fingerprint)
    }
}
