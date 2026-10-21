import AppKit

/// 搜索条目（预计算拼音与规范化匹配字段，避免每次按键重复计算）
struct SearchItem {
    let result: SearchResult
    let nameLower: String
    /// 去掉空白与符号的小写名，如 "wi-fi" → "wifi"
    let nameCompact: String
    let aliasLower: String
    let aliasCompact: String
    /// 简体中文名匹配字段（应用来自 bundle 内置本地化，设置项为固定清单）
    let zhLower: String
    let zhCompact: String
    let pinyinFull: String?
    let pinyinInitials: String?
}

/// 汇总应用与系统设置两个数据源，统一打分排序
@MainActor
final class SearchEngine {
    private var appItems: [SearchItem] = []
    private let settingItems: [SearchItem]
    private let maxResults = 9

    init() {
        settingItems = SystemSettingsCatalog.items.map(Self.makeItem)
    }

    /// 后台重新扫描应用目录（应用安装/删除后保持新鲜）
    @discardableResult
    func rescanApps() async -> Int {
        let scanned = await Task.detached(priority: .userInitiated) {
            AppIndexer.scan()
        }.value
        appItems = scanned.map(Self.makeItem)
        NSLog("[OpenMyApp] 应用索引已刷新: \(scanned.count) 个应用")
        return scanned.count
    }

    func search(_ rawQuery: String) -> [SearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }

        var scored: [(score: Int, result: SearchResult)] = []
        for item in appItems + settingItems {
            if let score = Self.score(item: item, query: query) {
                scored.append((score, item.result))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.result.title < rhs.result.title
        }
        return scored.prefix(maxResults).map(\.result)
    }

    // MARK: - Item 构建

    private static func makeItem(for app: IndexedApp) -> SearchItem {
        // 有中文名时优先作为展示名（拼音搜索场景下更直观）
        let title = app.chineseName ?? app.name
        let result = SearchResult(
            id: "app:\(app.path)",
            title: title,
            alias: app.englishName,
            kind: .application,
            icon: app.icon,
            appPath: app.path,
            settingAnchor: nil
        )
        let zhPinyin = app.chineseName.flatMap { Pinyin.info(for: $0) }
        let displayNamePinyin = Pinyin.info(for: app.name)
        return SearchItem(
            result: result,
            nameLower: title.lowercased(),
            nameCompact: compact(title),
            aliasLower: app.englishName.lowercased(),
            aliasCompact: compact(app.englishName),
            zhLower: app.chineseName?.lowercased() ?? "",
            zhCompact: compact(app.chineseName ?? ""),
            pinyinFull: displayNamePinyin?.full ?? zhPinyin?.full,
            pinyinInitials: displayNamePinyin?.initials ?? zhPinyin?.initials
        )
    }

    private static func makeItem(for setting: SettingsItem) -> SearchItem {
        let result = SearchResult(
            id: "setting:\(setting.anchor)",
            title: setting.zhName,
            alias: setting.enName,
            kind: .systemSetting,
            icon: symbolIcon(for: setting),
            appPath: nil,
            settingAnchor: setting.anchor
        )
        let pinyin = Pinyin.info(for: setting.zhName)
        return SearchItem(
            result: result,
            nameLower: setting.zhName.lowercased(),
            nameCompact: compact(setting.zhName),
            aliasLower: setting.enName.lowercased(),
            aliasCompact: compact(setting.enName),
            zhLower: setting.zhName.lowercased(),
            zhCompact: compact(setting.zhName),
            pinyinFull: pinyin?.full,
            pinyinInitials: pinyin?.initials
        )
    }

    private static func compact(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func symbolIcon(for setting: SettingsItem) -> NSImage {
        NSImage(systemSymbolName: setting.symbolName, accessibilityDescription: setting.zhName)
            ?? NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: setting.zhName)
            ?? NSImage()
    }

    // MARK: - 打分

    /// 返回 nil 表示不匹配；分数越高越靠前
    static func score(item: SearchItem, query query: String) -> Int? {
        var best = -1
        func consider(_ value: Int) {
            if value > best { best = value }
        }

        // 前缀 / 全等：最强信号
        if item.nameLower == query { consider(2000) }
        else if item.nameLower.hasPrefix(query) { consider(1800) }
        if item.pinyinFull == query { consider(1900) }
        else if item.pinyinFull?.hasPrefix(query) == true { consider(1600) }
        if item.pinyinInitials == query { consider(1500) }
        if item.nameCompact.hasPrefix(query) { consider(1650) }
        if item.aliasLower.hasPrefix(query) { consider(1700) }
        if item.aliasCompact.hasPrefix(query) { consider(1550) }

        // 中文名（zhLower / zhCompact）：与别名同档打分
        if item.zhLower.hasPrefix(query) { consider(1700) }
        if item.zhCompact.hasPrefix(query) { consider(1550) }
        if item.zhLower.contains(query) { consider(1100) }
        if item.zhCompact.contains(query) { consider(1050) }
        if isSubsequence(query, in: item.zhLower) || isSubsequence(query, in: item.zhCompact) { consider(750) }

        // 包含
        if item.nameLower.contains(query) { consider(1200) }
        if item.nameCompact.contains(query) { consider(1150) }
        if item.aliasLower.contains(query) { consider(1100) }
        if item.aliasCompact.contains(query) { consider(1050) }
        if item.pinyinFull?.contains(query) == true { consider(1000) }

        // 子序列（如 "vsc" → Visual Studio Code）
        if isSubsequence(query, in: item.nameLower) || isSubsequence(query, in: item.nameCompact) { consider(800) }
        if isSubsequence(query, in: item.aliasLower) || isSubsequence(query, in: item.aliasCompact) { consider(750) }
        if let full = item.pinyinFull, isSubsequence(query, in: full) { consider(700) }

        guard best > 0 else { return nil }

        // 使用频次加权（常用应用靠前）
        let usage = Preferences.usageCount(for: item.result.id)
        best += min(usage, 30) * 3
        if let last = Preferences.lastUsedDate(for: item.result.id),
           Date().timeIntervalSince(last) < 7 * 24 * 3600 {
            best += 60
        }
        return best
    }

    static func isSubsequence(_ query: String, in target: String) -> Bool {
        guard !query.isEmpty, query.count <= target.count else { return false }
        var searchStart = target.startIndex
        for character in query {
            guard let found = target[searchStart...].firstIndex(of: character) else { return false }
            searchStart = target.index(after: found)
        }
        return true
    }
}
