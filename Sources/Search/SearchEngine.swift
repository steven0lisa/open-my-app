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
    /// 扫描结果保鲜期：期内重扫直接跳过（目录变化由 FSEvents 强制触发）
    private static let freshInterval: TimeInterval = 60
    private var lastScanAt: Date?

    init() {
        settingItems = SystemSettingsCatalog.items.map(Self.makeItem)
    }

    /// 后台重新扫描应用目录；非强制时保鲜期内直接跳过（唤醒面板零工作）
    @discardableResult
    func rescanApps(force: Bool = false) async -> Int {
        if !force, let lastScanAt, Date().timeIntervalSince(lastScanAt) < Self.freshInterval {
            return appItems.count
        }
        let scanned = await Task.detached(priority: .utility) {
            AppIndexer.scan()
        }.value
        appItems = scanned.map(Self.makeItem)
        lastScanAt = Date()
        NSLog("[OpenMyApp] 应用索引已刷新: \(scanned.count) 个应用")
        return scanned.count
    }

    /// 空查询浏览态：全量应用按最常用排序（不含系统设置项，网格里只放应用）
    func allAppsByUsage() -> [SearchResult] {
        Self.sortByUsage(appItems.map { item in
            (result: item.result, usage: Preferences.usageCount(for: item.result.id))
        })
    }

    /// 浏览态排序：使用频次降序，同频次按展示名升序（纯函数，供单元测试）
    static func sortByUsage(_ apps: [(result: SearchResult, usage: Int)]) -> [SearchResult] {
        apps.sorted { lhs, rhs in
            if lhs.usage != rhs.usage { return lhs.usage > rhs.usage }
            return lhs.result.title < rhs.result.title
        }
        .map(\.result)
    }

    /// limit：结果上限（普通模式 app 结果压缩到 3 条，为剪切板结果腾位）
    func search(_ rawQuery: String, limit: Int? = nil) -> [SearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        let cap = limit ?? maxResults

        // 查询级预计算：ASCII 判定与字节序列每次搜索只做一次
        // （放在 isSubsequence 内做的话，每条目每次调用都要逐字符迭代一遍）
        let queryBytes = Array(query.utf8)
        let asciiQuery = query.allSatisfy(\.isASCII)

        // 不做数组拼接，避免每次按键的分配
        var scored: [(score: Int, result: SearchResult)] = []
        scored.reserveCapacity(appItems.count + settingItems.count)
        for item in appItems {
            if let score = Self.score(item: item, query: query, queryBytes: queryBytes, asciiQuery: asciiQuery) {
                scored.append((score, item.result))
            }
        }
        for item in settingItems {
            if let score = Self.score(item: item, query: query, queryBytes: queryBytes, asciiQuery: asciiQuery) {
                scored.append((score, item.result))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.result.title < rhs.result.title
        }
        return scored.prefix(cap).map(\.result)
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
            appPath: app.path,
            settingAnchor: nil,
            symbolName: nil,
            openPath: nil,
            clipItem: nil
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
            appPath: nil,
            settingAnchor: setting.anchor,
            symbolName: setting.symbolName,
            openPath: nil,
            clipItem: nil
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

    // MARK: - 打分

    /// 返回 nil 表示不匹配；分数越高越靠前
    static func score(item: SearchItem, query query: String, queryBytes: [UInt8], asciiQuery: Bool) -> Int? {
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
        if bytesContain(item.zhLower, query) { consider(1100) }
        if bytesContain(item.zhCompact, query) { consider(1050) }
        if asciiQuery {
            if isSubsequence(queryBytes, in: item.zhLower) || isSubsequence(queryBytes, in: item.zhCompact) { consider(750) }
        } else {
            if isSubsequenceCharacters(query, in: item.zhLower) || isSubsequenceCharacters(query, in: item.zhCompact) { consider(750) }
        }

        // 包含：走 UTF-8 字节级匹配（Foundation 的 String.contains 走 locale
        // 感知搜索，慢一个数量级；字节级子串匹配在 UTF-8 上天然字符对齐）
        if bytesContain(item.nameLower, query) { consider(1200) }
        if bytesContain(item.nameCompact, query) { consider(1150) }
        if bytesContain(item.aliasLower, query) { consider(1100) }
        if bytesContain(item.aliasCompact, query) { consider(1050) }
        if let full = item.pinyinFull, bytesContain(full, query) { consider(1000) }

        // 子序列（如 "vsc" → Visual Studio Code）
        if asciiQuery {
            if isSubsequence(queryBytes, in: item.nameLower) || isSubsequence(queryBytes, in: item.nameCompact) { consider(800) }
            if isSubsequence(queryBytes, in: item.aliasLower) || isSubsequence(queryBytes, in: item.aliasCompact) { consider(750) }
            if let full = item.pinyinFull, isSubsequence(queryBytes, in: full) { consider(700) }
        } else {
            if isSubsequenceCharacters(query, in: item.nameLower) || isSubsequenceCharacters(query, in: item.nameCompact) { consider(800) }
            if isSubsequenceCharacters(query, in: item.aliasLower) || isSubsequenceCharacters(query, in: item.aliasCompact) { consider(750) }
            if let full = item.pinyinFull, isSubsequenceCharacters(query, in: full) { consider(700) }
        }

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

    /// 字节级子串包含：手写首字节剪枝的朴素匹配，零堆分配。
    /// 不要用 utf8.firstRange(of:)——它每次调用都把两个串拷贝成连续数组建
    /// Z-Searcher（libswift_StringProcessing 的 ZSearcher），热点采样证实是
    /// 搜索热路径最大开销；也不要用 String.contains——走 Foundation 的
    /// locale 感知搜索，同样慢一个量级。
    /// nonisolated：纯函数无状态，剪切板后台搜索也复用。
    nonisolated static func bytesContain(_ haystack: String, _ needle: String) -> Bool {
        let hay = haystack.utf8
        let nee = needle.utf8
        guard !nee.isEmpty else { return true }
        guard hay.count >= nee.count, let first = nee.first else { return false }

        var searchStart = hay.startIndex
        while true {
            guard let firstPos = hay[searchStart...].firstIndex(of: first) else { return false }
            var i = firstPos
            var matched = 0
            for b in nee {
                if i == hay.endIndex || hay[i] != b { break }
                hay.formIndex(after: &i)
                matched += 1
            }
            if matched == nee.count { return true }
            if i == hay.endIndex { return false }
            searchStart = hay.index(after: firstPos)
        }
    }

    /// 字节级子序列：bytes 由调用方按查询预计算；扫描用 formIndex 手写推进，
    /// 不创建切片、不走泛型 firstIndex
    static func isSubsequence(_ bytes: [UInt8], in target: String) -> Bool {
        let view = target.utf8
        guard !bytes.isEmpty, bytes.count <= view.count else { return false }
        var idx = view.startIndex
        let end = view.endIndex
        for byte in bytes {
            while idx != end, view[idx] != byte {
                view.formIndex(after: &idx)
            }
            if idx == end { return false }
            view.formIndex(after: &idx)
        }
        return true
    }

    /// Character 级子序列（非 ASCII 查询用，避免跨字符边界的假匹配）
    static func isSubsequenceCharacters(_ query: String, in target: String) -> Bool {
        guard !query.isEmpty, query.count <= target.count else { return false }
        var searchStart = target.startIndex
        for character in query {
            guard let found = target[searchStart...].firstIndex(of: character) else { return false }
            searchStart = target.index(after: found)
        }
        return true
    }
}
