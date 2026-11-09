import XCTest
@testable import utility

final class ProcessRunnerTests: XCTestCase {
    func testGrandchildHoldingPipeMarksOutputIncomplete() {
        let result = ProcessRunner.runSync(
            ["/bin/sh", "-c", "sleep 5 & echo done"],
            timeout: 5,
        )
        XCTAssertTrue(result.outputIncomplete)
    }

    func testNormalCommandCompletes() {
        let result = ProcessRunner.runSync(["/bin/echo", "ok"], timeout: 5)
        XCTAssertFalse(result.outputIncomplete)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
    }
}
