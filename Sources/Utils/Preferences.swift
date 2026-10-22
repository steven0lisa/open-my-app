import Foundation
import Carbon.HIToolbox

/// 用户偏好与使用频次统计（UserDefaults 封装）
enum Preferences {
    private static let showMenuBarIconKey = "showMenuBarIcon"
    private static let usageCountKey = "usageCount"
    private static let usageLastKey = "usageLast"
    private static let hotkeyKeyCodeKey = "hotkeyKeyCode"
    private static let hotkeyCarbonMaskKey = "hotkeyCarbonMask"
    private static let clipboardHotkeyKeyCodeKey = "clipboardHotkeyKeyCode"
    private static let clipboardHotkeyCarbonMaskKey = "clipboardHotkeyCarbonMask"
    private static let clipboardLastCleanupKey = "clipboardLastCleanupAt"
    private static let launchAtLoginAutoConfiguredKey = "launchAtLoginAutoConfigured"

    // 使用频次缓存在内存：UserDefaults.dictionary(forKey:) 每次调用都会重新
    // 反序列化 plist，而打分热路径对每个索引条目都要读两次，必须走内存
    private static var usageCounts: [String: Int] =
        UserDefaults.standard.dictionary(forKey: usageCountKey) as? [String: Int] ?? [:]
    private static var usageLasts: [String: TimeInterval] =
        UserDefaults.standard.dictionary(forKey: usageLastKey) as? [String: TimeInterval] ?? [:]

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

    /// 剪切板模式快捷键主键（默认 V，配合 ⌘⇧）
    static var clipboardHotkeyKeyCode: Int {
        get { UserDefaults.standard.object(forKey: clipboardHotkeyKeyCodeKey) as? Int ?? Int(kVK_ANSI_V) }
        set { UserDefaults.standard.set(newValue, forKey: clipboardHotkeyKeyCodeKey) }
    }

    /// 剪切板模式快捷键修饰键（Carbon 掩码，默认 ⌘⇧）
    static var clipboardHotkeyCarbonMask: Int {
        get { UserDefaults.standard.object(forKey: clipboardHotkeyCarbonMaskKey) as? Int ?? Int(cmdKey | shiftKey) }
        set { UserDefaults.standard.set(newValue, forKey: clipboardHotkeyCarbonMaskKey) }
    }

    /// 剪切板模式快捷键的展示文本，如 "⌘⇧V"
    static var clipboardHotkeyDisplay: String {
        HotkeyDisplay.string(keyCode: UInt32(clipboardHotkeyKeyCode), carbonMask: UInt32(clipboardHotkeyCarbonMask))
    }

    /// 上次剪切板清理时间（epoch 秒；0 = 从未清理）
    static var clipboardLastCleanupAt: TimeInterval {
        get { UserDefaults.standard.object(forKey: clipboardLastCleanupKey) as? TimeInterval ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: clipboardLastCleanupKey) }
    }

    /// 是否已执行过「默认自启动」一次性引导。执行过之后一切以设置页开关为准，
    /// 后续启动不再自动注册（用户主动关掉的自启动不能被悄悄打开）
    static var launchAtLoginAutoConfigured: Bool {
        get { UserDefaults.standard.bool(forKey: launchAtLoginAutoConfiguredKey) }
        set { UserDefaults.standard.set(newValue, forKey: launchAtLoginAutoConfiguredKey) }
    }

    static func usageCount(for id: String) -> Int {
        usageCounts[id] ?? 0
    }

    static func lastUsedDate(for id: String) -> Date? {
        guard let timestamp = usageLasts[id] else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    static func recordUsage(for id: String) {
        usageCounts[id, default: 0] += 1
        usageLasts[id] = Date().timeIntervalSince1970
        let defaults = UserDefaults.standard
        defaults.set(usageCounts, forKey: usageCountKey)
        defaults.set(usageLasts, forKey: usageLastKey)
    }
}
