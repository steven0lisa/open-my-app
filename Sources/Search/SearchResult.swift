import AppKit

/// 搜索结果种类
enum ResultKind {
    case application
    case systemSetting

    var label: String {
        switch self {
        case .application: return "应用程序"
        case .systemSetting: return "系统设置"
        }
    }
}

/// 一条可执行动作的搜索结果
struct SearchResult: Identifiable, Equatable {
    /// 稳定 ID："app:<bundle路径>" 或 "setting:<设置面板锚点>"
    let id: String
    /// 展示名（本地化名，如「访达」）
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

    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.id == rhs.id
    }
}
