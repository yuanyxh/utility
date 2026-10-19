import Carbon
import Cocoa

/// Global hotkey manager (Carbon-based, correctly consumes events)
public final class HotkeyManager {
    public static let shared = HotkeyManager()
    private var handlers: [UInt32: () -> Void] = [:]
    private var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]

    private init() {}

    @discardableResult
    public func register(hotkey: String, id: String, handler: @escaping () -> Void) -> Bool {
        guard let (keyCode, flags) = parse(hotkey: hotkey) else {
            let msg = "[Hotkey] Failed to parse: \(hotkey)"
            fputs("\(msg)\n", stderr)
            debugLog(msg)
            EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                title: L10n.Notify.hotkeyParseFailed, body: "\(id): \(hotkey)",
            ))
            return false
        }

        let signature = fourCharCode(from: id)
        let hotkeyID = EventHotKeyID(signature: signature, id: 1)

        var hotkeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), flags, hotkeyID,
            GetEventDispatcherTarget(), 0, &hotkeyRef,
        )
        guard status == noErr else {
            let msg = "[Hotkey] Register failed \(hotkey) (\(id)) status=\(status)"
            fputs("\(msg)\n", stderr)
            debugLog(msg)
            EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                title: L10n.Notify.hotkeyRegisterFailed,
                body: L10n.Notify.hotkeyRegisterFailedBody(id: id, hotkey: hotkey),
            ))
            return false
        }

        handlers[signature] = handler
        hotkeyRefs[signature] = hotkeyRef
        return true
    }

    public func handleEvent(event: EventRef?) -> Bool {
        var hkID = EventHotKeyID()
        let err = GetEventParameter(
            event, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &hkID,
        )
        guard err == noErr else { return false }
        if let handler = handlers[hkID.signature] {
            handler()
            return true
        }
        return false
    }

    private func fourCharCode(from string: String) -> UInt32 {
        var code: UInt32 = 0
        for byte in string.utf8.prefix(4) {
            code = (code << 8) + UInt32(byte)
        }
        return code
    }

    private func parse(hotkey: String) -> (keyCode: UInt16, flags: UInt32)? {
        let parts = hotkey.lowercased().split(separator: "+").map(String.init)
        // keyCode 用 Optional:`a` 的 ANSI 键码就是 0,拿 0 当「还没匹配到」会让 `cmd+a` 解析失败
        var keyCode: UInt16?
        var flags: UInt32 = 0

        for part in parts {
            switch part {
            case "cmd", "command": flags |= UInt32(cmdKey)
            case "option", "alt": flags |= UInt32(optionKey)
            case "shift": flags |= UInt32(shiftKey)
            case "ctrl", "control": flags |= UInt32(controlKey)
            default:
                guard let code = keyCodeMap[part] else { return nil }
                keyCode = code
            }
        }
        guard let keyCode else { return nil }
        return (keyCode, flags)
    }
}

/// ANSI 键码（`kVK_ANSI_*`）。**必须完整** —— 缺一个键时 `parse` 返回 nil，
/// 症状是「配置看似正常却弹热键解析失败」，且失败的是用户自己配的那个键。
private let keyCodeMap: [String: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
    "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16,
    "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
    "n": 45, "m": 46,
    "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
    "7": 26, "8": 28, "9": 25, "0": 29,
    "-": 27, "=": 24, "[": 33, "]": 30, ";": 41, "'": 39, "\\": 42,
    ",": 43, ".": 47, "/": 44, "`": 50,
    "space": 49, "escape": 53, "return": 36, "tab": 48,
    "up": 126, "down": 125, "left": 123, "right": 124,
    "delete": 51, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
]
