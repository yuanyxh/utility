import XCTest
@testable import utility

@MainActor
final class SetupModelTests: XCTestCase {
    func testCheckAdvancesToInstallWhenOnlyOptionalItemMissing() {
        let model = SetupModel(onFinish: {})
        model.items = [
            SetupItem(id: .reranker, state: .missing, isRequired: false)
        ]
        model.nextFromCheck()
        XCTAssertEqual(model.step, .install)
        XCTAssertTrue(model.allRequiredOK)
        XCTAssertEqual(model.missingInstallable.map(\.id), [.reranker])
    }

    func testCheckFinishesWhenNothingIsMissing() {
        let model = SetupModel(onFinish: {})
        model.items = [SetupItem(id: .reranker, state: .ok, isRequired: false)]
        model.nextFromCheck()
        XCTAssertEqual(model.step, .done)
    }
}
