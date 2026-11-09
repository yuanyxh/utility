import XCTest
@testable import utility

final class RerankEnvironmentTests: XCTestCase {
    func testRerankEnvironmentInjectsModelDirectory() {
        let env = PythonScriptRunner.rerankEnvironment()
        XCTAssertEqual(env["RERANK_MODEL_DIR"], AppPaths.rerankerModelDir.path)
        XCTAssertFalse(env["RERANK_MODEL_DIR"]?.isEmpty ?? true)
    }
}
