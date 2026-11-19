import XCTest
@testable import SetlistCore

final class FingerprintTests: XCTestCase {
    /// Deterministic pseudo-random values, so the tests do not depend on the system generator.
    private func random(_ count: Int, seed: UInt64) -> Fingerprint {
        var state = seed
        return Fingerprint(values: (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt32(truncatingIfNeeded: state >> 32)
        })
    }

    func testIdenticalIsOne() {
        let a = random(500, seed: 1)
        XCTAssertEqual(FingerprintCompare.similarity(a, a), 1, accuracy: 1e-9)
    }

    func testRandomIsNearHalf() {
        let score = FingerprintCompare.similarity(random(500, seed: 1), random(500, seed: 2))
        XCTAssertTrue((0.4...0.6).contains(score), "\(score)")
    }

    func testShiftedCopyScoresHigh() {
        let a = random(500, seed: 3)
        let b = Fingerprint(values: Array(a.values.dropFirst(37)))
        XCTAssertGreaterThanOrEqual(FingerprintCompare.similarity(a, b), 0.99)
        XCTAssertGreaterThanOrEqual(FingerprintCompare.similarity(b, a), 0.99)
    }

    func testTooShortIsZero() {
        XCTAssertEqual(FingerprintCompare.similarity(random(30, seed: 4), random(500, seed: 4)), 0)
        XCTAssertEqual(FingerprintCompare.similarity(Fingerprint(values: []), random(500, seed: 4)), 0)
    }

    func testParsesFpcalcJSON() async throws {
        let runner = FakeRunner(results: [.ok(#"{"duration": 12.5, "fingerprint": [1, 2, 4294967295]}"#)])
        let fingerprinter = Fingerprinter(runner: runner, locator: try TestTools.locator())
        let file = URL(fileURLWithPath: "/tmp/a.wav")
        let fingerprint = try await fingerprinter.fingerprint(file: file, maxLength: 90)
        XCTAssertEqual(fingerprint, Fingerprint(values: [1, 2, 4_294_967_295]))
        XCTAssertEqual(runner.calls.first?.executable, "fpcalc")
        XCTAssertEqual(runner.calls.first?.arguments, ["-raw", "-json", "-length", "90", "/tmp/a.wav"])
    }

    func testFpcalcFailureThrows() async throws {
        let fingerprinter = Fingerprinter(runner: FakeRunner(results: [.fail("bad file")]), locator: try TestTools.locator())
        do {
            _ = try await fingerprinter.fingerprint(file: URL(fileURLWithPath: "/tmp/a.wav"))
            XCTFail("expected throw")
        } catch let error as ToolError {
            XCTAssertEqual(error, .failed(.fpcalc, exitCode: 1, stderr: "bad file"))
        }
    }
}
