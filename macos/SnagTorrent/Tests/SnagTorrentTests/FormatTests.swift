import XCTest
@testable import SnagTorrent

final class FormatTests: XCTestCase {
    func testPercent() {
        XCTAssertEqual(Format.percent(0), "0.0%")
        XCTAssertEqual(Format.percent(0.4567), "45.7%")
        XCTAssertEqual(Format.percent(0.9996), "99.9%", "never rounds up to 100% before completion")
        XCTAssertEqual(Format.percent(1), "100%")
        XCTAssertEqual(Format.percent(1.5), "100%")
        XCTAssertEqual(Format.percent(-1), "0.0%")
    }

    func testEta() {
        XCTAssertEqual(Format.eta(nil), "—")
        XCTAssertEqual(Format.eta(42), "42s")
        XCTAssertEqual(Format.eta(125), "2m 5s")
        XCTAssertEqual(Format.eta(3_600 * 5 + 60 * 7), "5h 7m")
        XCTAssertEqual(Format.eta(3_600 * 50), "2d 2h")
    }

    func testSizesAndRates() {
        XCTAssertEqual(Format.size(0), "—")
        XCTAssertEqual(Format.rate(0), "—")
        XCTAssertTrue(Format.rate(1_500_000).hasSuffix("/s"))
        XCTAssertFalse(Format.size(276_445_467).isEmpty)
    }
}
