import XCTest
@testable import SetlistCore

final class SmokeTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(SetlistCore.version, "0.1.0")
    }
}
