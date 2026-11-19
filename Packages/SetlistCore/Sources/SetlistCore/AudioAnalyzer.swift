import Accelerate
import AVFoundation
import Foundation

/// Estimates tempo and musical key of an audio file, entirely on-device.
///
/// Tempo: spectral-flux onset envelope → autocorrelation over the 60–200 BPM lag range with a mild
/// prior around 120 BPM. Key: 12-bin chroma from an STFT, correlated against Krumhansl-Schmuckler
/// major/minor profiles for all 24 keys.
public struct AudioAnalyzer: Sendable {
    public enum Error: Swift.Error, Equatable {
        case tooShort(seconds: Double)
        case unreadable(String)
    }

    public static let analysisRate: Double = 11_025
    /// Only this much audio from the middle of the file is analysed, for speed.
    public var maxSeconds: Double = 180

    public init() {}

    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    public static func camelot(pitchClass: Int, minor: Bool) -> String {
        // Relative major of a minor key is three semitones up; the wheel then follows the circle of fifths from C = 8.
        let major = minor ? (pitchClass + 3) % 12 : pitchClass % 12
        let number = ((major * 7) % 12 + 7) % 12 + 1
        return "\(number)\(minor ? "A" : "B")"
    }

    public static func keyName(pitchClass: Int, minor: Bool) -> String {
        "\(noteNames[pitchClass % 12]) \(minor ? "minor" : "major")"
    }

    /// ID3 TKEY form: "Am", "F#", "C".
    public static func id3Key(pitchClass: Int, minor: Bool) -> String {
        noteNames[pitchClass % 12] + (minor ? "m" : "")
    }

    public func analyze(file: URL) throws -> TrackAnalysis {
        let samples = try loadMono(file)
        let seconds = Double(samples.count) / Self.analysisRate
        guard seconds >= 2 else { throw Error.tooShort(seconds: seconds) }

        let (pitchClass, minor) = Self.estimateKey(samples)
        let bpm = Self.estimateTempo(samples)
        return TrackAnalysis(bpm: bpm, camelot: Self.camelot(pitchClass: pitchClass, minor: minor), keyName: Self.keyName(pitchClass: pitchClass, minor: minor))
    }

    // MARK: Loading

    private func loadMono(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw Error.unreadable(error.localizedDescription) }
        let sourceRate = file.processingFormat.sampleRate
        let total = Double(file.length) / sourceRate
        let window = min(total, maxSeconds)
        let start = max(0, (total - window) / 2)
        file.framePosition = AVAudioFramePosition(start * sourceRate)
        let wanted = AVAudioFrameCount(window * sourceRate)

        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: wanted),
              let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: wanted) else {
            throw Error.unreadable("could not allocate buffers")
        }
        while source.frameLength < wanted {
            do { try file.read(into: chunk, frameCount: wanted - source.frameLength) } catch { break }
            guard chunk.frameLength > 0, let dst = source.floatChannelData, let src = chunk.floatChannelData else { break }
            for ch in 0..<Int(source.format.channelCount) {
                dst[ch].advanced(by: Int(source.frameLength)).update(from: src[ch], count: Int(chunk.frameLength))
            }
            source.frameLength += chunk.frameLength
        }

        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.analysisRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: source.format, to: target) else { throw Error.unreadable("no converter") }
        let capacity = AVAudioFrameCount(Double(source.frameLength) * target.sampleRate / source.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw Error.unreadable("could not allocate output") }
        final class Once: @unchecked Sendable { var consumed = false }
        let once = Once()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if once.consumed { outStatus.pointee = .endOfStream; return nil }
            once.consumed = true
            outStatus.pointee = .haveData
            return source
        }
        if status == .error { throw Error.unreadable(conversionError?.localizedDescription ?? "conversion failed") }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    // MARK: STFT

    /// Magnitude spectra (size n/2) for frames of `n` samples every `hop` samples, Hann-windowed.
    private static func spectra(_ samples: [Float], n: Int, hop: Int) -> [[Float]] {
        guard samples.count >= n else { return [] }
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        let half = n / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: n)
        var magnitudes = [Float](repeating: 0, count: half)
        var frames: [[Float]] = []
        frames.reserveCapacity((samples.count - n) / hop + 1)

        var offset = 0
        while offset + n <= samples.count {
            samples.withUnsafeBufferPointer { buf in
                vDSP_vmul(buf.baseAddress! + offset, 1, window, 1, &windowed, 1, vDSP_Length(n))
            }
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    windowed.withUnsafeBufferPointer { w in
                        w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                }
            }
            frames.append(magnitudes)
            offset += hop
        }
        return frames
    }

    // MARK: Key

    private static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func estimateKey(_ samples: [Float]) -> (pitchClass: Int, minor: Bool) {
        let n = 4096, hop = 2048
        let frames = spectra(samples, n: n, hop: hop)
        var chroma = [Float](repeating: 0, count: 12)
        let binHz = Float(analysisRate) / Float(n)
        for frame in frames {
            for bin in 1..<frame.count {
                let f = Float(bin) * binHz
                guard f >= 55, f <= 2_000 else { continue }
                let midi = 12 * log2(f / 440) + 69
                let pc = (Int(midi.rounded()) % 12 + 12) % 12
                chroma[pc] += frame[bin]
            }
        }
        var best = (score: -Float.infinity, pc: 0, minor: false)
        for pc in 0..<12 {
            let rotated = (0..<12).map { chroma[(pc + $0) % 12] }
            let major = correlation(rotated, majorProfile)
            let minor = correlation(rotated, minorProfile)
            if major > best.score { best = (major, pc, false) }
            if minor > best.score { best = (minor, pc, true) }
        }
        return (best.pc, best.minor)
    }

    private static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num: Float = 0, da: Float = 0, db: Float = 0
        for i in 0..<a.count {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        return da > 0 && db > 0 ? num / sqrt(da * db) : 0
    }

    // MARK: Tempo

    static func estimateTempo(_ samples: [Float]) -> Int {
        let n = 1024, hop = 256
        let fps = analysisRate / Double(hop)
        let frames = spectra(samples, n: n, hop: hop)
        guard frames.count > 8 else { return 0 }

        // Onset envelope: half-wave rectified spectral flux on log magnitudes.
        var envelope = [Float](repeating: 0, count: frames.count)
        var previous = frames[0].map { log1p($0) }
        for i in 1..<frames.count {
            let current = frames[i].map { log1p($0) }
            var flux: Float = 0
            for b in 0..<current.count { flux += max(0, current[b] - previous[b]) }
            envelope[i] = flux
            previous = current
        }
        let mean = envelope.reduce(0, +) / Float(envelope.count)
        envelope = envelope.map { $0 - mean }

        let minLag = Int(fps * 60 / 200), maxLag = Int(fps * 60 / 60)
        guard envelope.count > maxLag + 2 else { return 0 }
        // Autocorrelation for every lag we care about, plus one on each side for interpolation.
        var autocorr = [Float](repeating: 0, count: maxLag + 2)
        for lag in (minLag - 1)...(maxLag + 1) {
            var sum: Float = 0
            for i in lag..<envelope.count { sum += envelope[i] * envelope[i - lag] }
            autocorr[lag] = sum
        }
        var best = (score: -Float.infinity, lag: minLag)
        for lag in minLag...maxLag {
            let bpm = fps * 60 / Double(lag)
            // Log-normal prior centred on 120 BPM, as common tempo estimators use.
            let prior = Float(exp(-0.5 * pow(log2(bpm / 120), 2)))
            let score = autocorr[lag] * prior
            if score > best.score { best = (score, lag) }
        }
        // Parabolic interpolation around the peak gives a fractional lag, so 21.5 frames is not read as 21 or 22.
        let y0 = autocorr[best.lag - 1], y1 = autocorr[best.lag], y2 = autocorr[best.lag + 1]
        let denom = y0 - 2 * y1 + y2
        let shift = denom != 0 ? max(-0.5, min(0.5, 0.5 * (y0 - y2) / denom)) : 0
        let lag = Double(best.lag) + Double(shift)
        return Int((fps * 60 / lag).rounded())
    }
}
