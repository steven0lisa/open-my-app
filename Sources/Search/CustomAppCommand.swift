import Foundation

/// 自定义目录命令：把一个前缀绑定到一个已安装应用（如 "zcode" → Zed.app）。
/// 输入「前缀 + 空格 + 关键字」（或前缀的唯一缩写，如 "z"）搜索目录，
/// 回车用该应用打开选中的目录。
struct CustomAppCommand: Codable, Equatable, Identifiable {
    let id: UUID
    /// 触发词；命令解析按大小写折叠比较，含空白的前缀无法作为单词触发
    var prefix: String
    /// 展示名（结果行右侧标签与标题用）
    var appName: String
    /// 应用 bundle 路径（图标与打开动作都按路径解析）
    var appPath: String
}
