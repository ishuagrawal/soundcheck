import XCTest
@testable import Soundcheck

final class AudioActivityTests: XCTestCase {
    func testSilenceAndInvalidSamplesNeverInventActivity() {
        var activity = AudioActivity()
        for peak: Float in [0, -1, .nan, .infinity, 0.00001] { activity.append(peak: peak) }
        XCTAssertFalse(activity.isAudible)
        XCTAssertFalse(activity.hasHistory)
    }

    func testMeasuredSignalAttacksAndDecaysBackToSilence() {
        var activity = AudioActivity()
        activity.append(peak: 0.1, at: 10)
        XCTAssertTrue(activity.isAudible)
        XCTAssertGreaterThan(activity.level, 0.5)
        XCTAssertEqual(activity.timestamp, 10)
        for _ in 0..<80 { activity.append(peak: 0) }
        XCTAssertEqual(activity.samples.count, AudioActivity.capacity)
        XCTAssertFalse(activity.hasHistory)
        XCTAssertFalse(activity.isAudible)
    }

    func testOverRangeInputStaysWithinDrawingBounds() {
        var activity = AudioActivity()
        for _ in 0..<100 { activity.append(peak: 1000) }
        XCTAssertTrue(activity.samples.allSatisfy { $0 >= 0 && $0 <= 1 })
    }
}
