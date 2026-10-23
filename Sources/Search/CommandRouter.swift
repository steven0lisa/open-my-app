import Foundation

/// 目录搜索命令的目标动作：内置 Terminal / Finder，或用户绑定的自定义应用
enum CommandMode: Equatable {
    case terminal
    case finder
    case customApp(CustomAppCommand)
}

/// 「命令词 + 空格 + 关键字」的解析：内置命令词 t / terminal、o / open 之外，
/// 还支持自定义前缀（Preferences.customAppCommands）与其唯一缩写。
/// 解析逻辑纯函数化（custom 由调用方从 Preferences 传入），便于离线测试。
enum CommandRouter {
    /// 解析失败返回 nil，走普通 app 搜索
    static func parse(_ raw: String, custom: [CustomAppCommand]) -> (mode: CommandMode, keyword: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let spaceIndex = trimmed.firstIndex(of: " ") else {
            // 无参数：只有完整命令词才进入命令态（空面板）；缩写不带关键字时仍走普通
            // app 搜索——否则配置了 "zcode" 后输入 "z" 就再也搜不到 z 开头的应用
            guard let mode = resolveToken(trimmed, custom: custom, allowAbbreviation: false) else {
                return nil
            }
            return (mode, "")
        }
        let token = String(trimmed[..<spaceIndex])
        let keyword = trimmed[trimmed.index(after: spaceIndex)...].trimmingCharacters(in: .whitespaces)
        guard let mode = resolveToken(token, custom: custom, allowAbbreviation: true) else { return nil }
        return (mode, keyword)
    }

    /// 命令词 → 动作。完全匹配优先（自定义前缀可覆盖内置词——用户显式配置即意图）；
    /// 内置词仅完整匹配（与历史行为一致），缩写只在自定义前缀里找，且必须唯一命中
    static func resolveToken(_ token: String, custom: [CustomAppCommand], allowAbbreviation: Bool) -> CommandMode? {
        let lower = token.lowercased()
        guard !lower.isEmpty else { return nil }
        if let exact = custom.first(where: { $0.prefix.lowercased() == lower }) {
            return .customApp(exact)
        }
        switch lower {
        case "t", "terminal":
            return .terminal
        case "o", "open":
            return .finder
        default:
            break
        }
        guard allowAbbreviation else { return nil }
        let matches = custom.filter { $0.prefix.lowercased().hasPrefix(lower) }
        guard matches.count == 1 else { return nil }
        return .customApp(matches[0])
    }
}
