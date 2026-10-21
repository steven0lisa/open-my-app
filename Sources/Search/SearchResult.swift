import AppKit

/// 搜索结果种类
enum ResultKind {
    case application
    case systemSetting
    /// `t ` 命令：用 Terminal 打开目录
    case terminal
    /// `o ` 命令：用 Finder 打开目录 / 文件
    case finder

    var label: String {
        switch self {
        case .application: return NSLocalizedString("App", comment: "result kind")
        case .systemSetting: return NSLocalizedString("System Setting", comment: "result kind")
        case .terminal: return "Terminal"
        case .finder: return "Finder"
        }
    }
}

/// 一条可执行动作的搜索结果
struct SearchResult: Identifiable, Equatable {
    /// 稳定 ID："app:<bundle路径>" / "setting:<锚点>" / "terminal:<路径>" / "finder:<路径>"
    let id: String
    /// 展示名（本地化名，如「访达」；命令模式下为完整动作句）
    let title: String
    /// 别名（应用英文原名 / 设置项英文名）
    let alias: String
    let kind: ResultKind
    /// 应用程序：bundle 路径
    let appPath: String?
    /// 系统设置：x-apple.systempreferences 锚点
    let settingAnchor: String?
    /// 系统设置项的 SF Symbol 名（应用图标走 NSWorkspace 按需获取，不常驻内存）
    let symbolName: String?
    /// 命令模式：Terminal / Finder 要打开的目标路径
    let openPath: String?

    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.id == rhs.id
    }
}
