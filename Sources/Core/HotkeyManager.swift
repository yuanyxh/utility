import Cocoa
import Carbon

/// 全局热键管理器（基于 Carbon，正确消耗事件）
public final class HotkeyManager {
    public static let shared = HotkeyManager()
    private var handlers: [UInt32: () -> Void] = [:]
    private var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]

    private init() {}

    @discardableResult
    public func register(hotkey: String, id: String, handler: @escaping () -> Void) -> Bool {
        guard let (keyCode, flags) = parse(hotkey: hotkey) else {
            fputs("[Hotkey] Failed to parse: \(hotkey)\n", stderr)
            return false
        }

        let signature = fourCharCode(from: id)
        let hotkeyID = EventHotKeyID(signature: signature, id: 1)

        var hotkeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), flags, hotkeyID,
                                          GetEventDispatcherTarget(), 0, &hotkeyRef)
        guard status == noErr else {
            fputs("[Hotkey] Register failed \(hotkey) (\(id)) status=\(status)\n", stderr)
            return false
        }

        handlers[signature] = handler
        hotkeyRefs[signature] = hotkeyRef
        return true
    }

    public func handleEvent(event: EventRef?) -> Bool {
        var hkID = EventHotKeyID()
        let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                     EventParamType(typeEventHotKeyID), nil,
                                     MemoryLayout<EventHotKeyID>.size, nil, &hkID)
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
        var keyCode: UInt16 = 0
        var flags: UInt32 = 0

        for part in parts {
            switch part {
            case "cmd", "command":  flags |= UInt32(cmdKey)
            case "option", "alt":   flags |= UInt32(optionKey)
            case "shift":           flags |= UInt32(shiftKey)
            case "ctrl", "control": flags |= UInt32(controlKey)
            default:
                guard let code = keyCodeMap[part] else { return nil }
                keyCode = code
            }
        }
        guard keyCode != 0 else { return nil }
        return (keyCode, flags)
    }
}

private let keyCodeMap: [String: UInt16] = [
    "c": 8, "d": 2, "f": 3, "v": 9, "s": 1, "a": 0,
    "x": 7, "z": 6, "w": 13, "q": 12, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
    "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
    "space": 49, "escape": 53, "return": 36, "tab": 48,
    "up": 126, "down": 125, "left": 123, "right": 124,
    "delete": 51, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
]
