import Foundation
import Carbon.HIToolbox

/// 用户偏好与使用频次统计（UserDefaults 封装）
enum Preferences {
    private static let showMenuBarIconKey = "showMenuBarIcon"
    private static let usageCountKey = "usageCount"
    private static let usageLastKey = "usageLast"
    private static let hotkeyKeyCodeKey = "hotkeyKeyCode"
    private static let hotkeyCarbonMaskKey = "hotkeyCarbonMask"

    /// 是否显示菜单栏（托盘）图标；隐藏后仍可用全局快捷键唤出搜索框
    static var showMenuBarIcon: Bool {
        get { UserDefaults.standard.object(forKey: showMenuBarIconKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showMenuBarIconKey) }
    }

    /// 全局快捷键主键（默认 Space）
    static var hotkeyKeyCode: Int {
        get { UserDefaults.standard.object(forKey: hotkeyKeyCodeKey) as? Int ?? Int(kVK_Space) }
        set { UserDefaults.standard.set(newValue, forKey: hotkeyKeyCodeKey) }
    }

    /// 全局快捷键修饰键（Carbon 掩码，默认 ⌥）
    static var hotkeyCarbonMask: Int {
        get { UserDefaults.standard.object(forKey: hotkeyCarbonMaskKey) as? Int ?? Int(optionKey) }
        set { UserDefaults.standard.set(newValue, forKey: hotkeyCarbonMaskKey) }
    }

    /// 当前快捷键的展示文本，如 "⌥Space"
    static var hotkeyDisplay: String {
        HotkeyDisplay.string(keyCode: UInt32(hotkeyKeyCode), carbonMask: UInt32(hotkeyCarbonMask))
    }

    static func usageCount(for id: String) -> Int {
        let counts = UserDefaults.standard.dictionary(forKey: usageCountKey) as? [String: Int]
        return counts?[id] ?? 0
    }

    static func lastUsedDate(for id: String) -> Date? {
        let lasts = UserDefaults.standard.dictionary(forKey: usageLastKey) as? [String: TimeInterval]
        guard let timestamp = lasts?[id] else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    static func recordUsage(for id: String) {
        let defaults = UserDefaults.standard
        var counts = defaults.dictionary(forKey: usageCountKey) as? [String: Int] ?? [:]
        counts[id, default: 0] += 1
        var lasts = defaults.dictionary(forKey: usageLastKey) as? [String: TimeInterval] ?? [:]
        lasts[id] = Date().timeIntervalSince1970
        defaults.set(counts, forKey: usageCountKey)
        defaults.set(lasts, forKey: usageLastKey)
    }
}
