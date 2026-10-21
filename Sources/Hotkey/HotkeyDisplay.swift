import AppKit
import Carbon.HIToolbox
import Foundation

/// 快捷键展示（keyCode + Carbon 修饰键掩码 → "⌥Space" 形式）
enum HotkeyDisplay {
    static func string(keyCode: UInt32, carbonMask: UInt32) -> String {
        var symbols = ""
        if carbonMask & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonMask & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonMask & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonMask & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols + keyName(keyCode)
    }

    static let keyNames: [Int: String] = [
        // 字母（ANSI 布局）
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        // 数字与符号
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
        // 常用键
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        // 方向与翻页
        115: "Home", 116: "Page Up", 119: "End", 121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        // 功能键
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15",
    ]

    static func keyName(_ keyCode: UInt32) -> String {
        keyNames[Int(keyCode)] ?? "Key(\(keyCode))"
    }

    /// NSEvent.ModifierFlags → Carbon 修饰键掩码
    static func carbonMask(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }
}
