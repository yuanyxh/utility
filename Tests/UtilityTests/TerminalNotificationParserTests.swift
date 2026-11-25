import XCTest

@testable import utility

final class TerminalNotificationParserTests: XCTestCase {
    private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    func testDrainsOsc777TerminatedByBEL() {
        var buffer = bytes("\u{1B}]777;notify;完成;任务结束\u{07}tail")
        let messages = TerminalNotificationParser.drain(&buffer)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.title, "完成")
        XCTAssertEqual(messages.first?.body, "任务结束")
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainsOsc9TerminatedByST() {
        var buffer = bytes("\u{1B}]9;构建完成\u{1B}\\")
        let messages = TerminalNotificationParser.drain(&buffer)
        XCTAssertEqual(messages.first?.body, "构建完成")
    }

    func testWaitsForSplitSequence() {
        var buffer = bytes("\u{1B}]777;notify;标题;正")
        XCTAssertTrue(TerminalNotificationParser.drain(&buffer).isEmpty)
        buffer += bytes("在运行\u{07}")
        let messages = TerminalNotificationParser.drain(&buffer)
        XCTAssertEqual(messages.first?.body, "正在运行")
    }

    func testDrainsMultipleMessages() {
        var buffer = bytes("\u{1B}]777;notify;a;1\u{07}\u{1B}]9;b\u{07}")
        XCTAssertEqual(TerminalNotificationParser.drain(&buffer).count, 2)
    }

    func testIgnoresProgressAndNonOscBytes() {
        var buffer = bytes("plain\u{1B}[31mred\u{1B}]9;4;1;50\u{07}")
        XCTAssertTrue(TerminalNotificationParser.drain(&buffer).isEmpty)
        XCTAssertTrue(buffer.isEmpty)
    }
}
