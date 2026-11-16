import XCTest

@testable import utility

final class HotkeyKeyMapTests: XCTestCase {
    func testEveryLetterParses() {
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            XCTAssertNotNil(HotkeyManager.parse(hotkey: "cmd+\(letter)"), "cmd+\(letter)")
        }
    }

    func testLetterAUsesKeyCodeZero() {
        XCTAssertEqual(HotkeyManager.parse(hotkey: "cmd+a")?.keyCode, 0)
    }

    func testSymbolsAndNamedKeysParse() {
        let keys = [
            "1", "0", "-", "=", "[", "]", ";", "'", "\\", ",", ".", "/", "`",
            "space", "escape", "return", "tab", "up", "down", "left", "right",
            "delete", "home", "end", "pageup", "pagedown",
        ]
        for key in keys {
            XCTAssertNotNil(HotkeyManager.parse(hotkey: "ctrl+\(key)"), "ctrl+\(key)")
        }
    }

    func testUnknownKeyIsRejected() {
        XCTAssertNil(HotkeyManager.parse(hotkey: "cmd+nosuchkey"))
    }
}
