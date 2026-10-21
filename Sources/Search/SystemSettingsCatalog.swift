import AppKit

/// 系统设置面板条目（macOS 13+ 设置扩展锚点）
struct SettingsItem {
    let anchor: String
    let zhName: String
    let enName: String
    let symbolName: String
}

enum SystemSettingsCatalog {
    static let items: [SettingsItem] = [
        SettingsItem(anchor: "com.apple.wifi-settings-extension", zhName: "Wi-Fi", enName: "Wi-Fi", symbolName: "wifi"),
        SettingsItem(anchor: "com.apple.BluetoothSettings-extension", zhName: "蓝牙", enName: "Bluetooth", symbolName: "wave.3.right"),
        SettingsItem(anchor: "com.apple.Network-Settings.extension", zhName: "网络", enName: "Network", symbolName: "network"),
        SettingsItem(anchor: "com.apple.Notifications-Settings.extension", zhName: "通知", enName: "Notifications", symbolName: "bell.badge"),
        SettingsItem(anchor: "com.apple.Sound-Settings.extension", zhName: "声音", enName: "Sound", symbolName: "speaker.wave.2.fill"),
        SettingsItem(anchor: "com.apple.Displays-Settings.extension", zhName: "显示器", enName: "Displays", symbolName: "display"),
        SettingsItem(anchor: "com.apple.Wallpaper-Settings.extension", zhName: "墙纸", enName: "Wallpaper", symbolName: "photo"),
        SettingsItem(anchor: "com.apple.Screen-Saver-Settings.extension", zhName: "屏幕保护程序", enName: "Screen Saver", symbolName: "display.and.arrow.down"),
        SettingsItem(anchor: "com.apple.Appearance-Settings.extension", zhName: "外观", enName: "Appearance", symbolName: "circle.lefthalf.filled"),
        SettingsItem(anchor: "com.apple.Accessibility-Settings.extension", zhName: "辅助功能", enName: "Accessibility", symbolName: "accessibility"),
        SettingsItem(anchor: "com.apple.Control-Center-Settings.extension", zhName: "控制中心", enName: "Control Center", symbolName: "switch.2"),
        SettingsItem(anchor: "com.apple.Desktop-Settings.extension", zhName: "桌面与程序坞", enName: "Desktop & Dock", symbolName: "menubar.dock.rectangle"),
        SettingsItem(anchor: "com.apple.Spotlight-Settings.extension", zhName: "聚焦", enName: "Spotlight", symbolName: "magnifyingglass"),
        SettingsItem(anchor: "com.apple.Siri-Settings.extension", zhName: "Siri 与聚焦", enName: "Siri & Spotlight", symbolName: "mic.fill"),
        SettingsItem(anchor: "com.apple.Privacy-Security-Settings.extension", zhName: "隐私与安全性", enName: "Privacy & Security", symbolName: "hand.raised.fill"),
        SettingsItem(anchor: "com.apple.Users-Groups-Settings.extension", zhName: "用户与群组", enName: "Users & Groups", symbolName: "person.2"),
        SettingsItem(anchor: "com.apple.Passwords-Settings.extension", zhName: "密码", enName: "Passwords", symbolName: "key.fill"),
        SettingsItem(anchor: "com.apple.Keyboard-Settings.extension", zhName: "键盘", enName: "Keyboard", symbolName: "keyboard"),
        SettingsItem(anchor: "com.apple.Mouse-Settings.extension", zhName: "鼠标", enName: "Mouse", symbolName: "computermouse"),
        SettingsItem(anchor: "com.apple.Trackpad-Settings.extension", zhName: "触控板", enName: "Trackpad", symbolName: "rectangle.on.rectangle"),
        SettingsItem(anchor: "com.apple.Print-Settings.extension", zhName: "打印机与扫描仪", enName: "Printers & Scanners", symbolName: "printer"),
        SettingsItem(anchor: "com.apple.Battery-Settings.extension", zhName: "电池", enName: "Battery", symbolName: "battery.100"),
        SettingsItem(anchor: "com.apple.Screen-Time-Settings.extension", zhName: "屏幕使用时间", enName: "Screen Time", symbolName: "hourglass"),
        SettingsItem(anchor: "com.apple.Software-Update-Settings.extension", zhName: "软件更新", enName: "Software Update", symbolName: "arrow.triangle.2.circlepath"),
        SettingsItem(anchor: "com.apple.Storage-Settings.extension", zhName: "储存空间", enName: "Storage", symbolName: "internaldrive"),
        SettingsItem(anchor: "com.apple.AirDrop-Handoff-Settings.extension", zhName: "隔空投送与接力", enName: "AirDrop & Handoff", symbolName: "dot.radiowaves.left.and.right"),
        SettingsItem(anchor: "com.apple.LoginItems-Settings.extension", zhName: "登录项与扩展", enName: "Login Items", symbolName: "powerplug.fill"),
        SettingsItem(anchor: "com.apple.Time-Machine-Settings.extension", zhName: "时间机器", enName: "Time Machine", symbolName: "arrow.counterclockwise.circle"),
        SettingsItem(anchor: "com.apple.Sharing-Settings.extension", zhName: "共享", enName: "Sharing", symbolName: "square.and.arrow.up"),
        SettingsItem(anchor: "com.apple.Language-Region-Settings.extension", zhName: "语言与地区", enName: "Language & Region", symbolName: "globe"),
        SettingsItem(anchor: "com.apple.Date-Time-Settings.extension", zhName: "日期与时间", enName: "Date & Time", symbolName: "clock"),
        SettingsItem(anchor: "com.apple.Startup-Disk-Settings.extension", zhName: "启动磁盘", enName: "Startup Disk", symbolName: "opticaldiscdrive"),
        SettingsItem(anchor: "com.apple.Internet-Accounts-Settings.extension", zhName: "互联网账户", enName: "Internet Accounts", symbolName: "at"),
        SettingsItem(anchor: "com.apple.Game-Center-Settings.extension", zhName: "游戏中心", enName: "Game Center", symbolName: "gamecontroller"),
        SettingsItem(anchor: "com.apple.Wallet-Settings.extension", zhName: "钱包与 Apple Pay", enName: "Wallet & Apple Pay", symbolName: "creditcard"),
        SettingsItem(anchor: "com.apple.Family-Settings.extension", zhName: "家庭", enName: "Family", symbolName: "house.fill"),
    ]

    /// 通过锚点打开对应系统设置面板
    static func open(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
