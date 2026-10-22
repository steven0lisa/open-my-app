import Foundation

/// 搜索框视图模型：持有查询状态与结果列表，桥接 SearchEngine 与 UI
@MainActor
final class LauncherModel: ObservableObject {
    /// 面板搜索模式：普通（app+设置+剪切板）与剪切板（只搜剪切板历史）
    enum SearchMode {
        case all
        case clipboard
    }

    /// 普通模式 app 结果上限（剪切板结果同限，共 6 行，双源都拿到即止）
    static let appResultLimit = 3
    static let clipResultLimit = 3

    /// focusToken 变化用于在面板重新显示时让输入框重新获得焦点
    @Published var focusToken = 0
    @Published var query: String = "" {
        didSet {
            if query != oldValue { scheduleRefresh() }
        }
    }
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedID: String?
    private(set) var searchMode: SearchMode = .all

    var onActivate: ((SearchResult) -> Void)?
    var onOpenSettings: (() -> Void)?
    /// 剪切板数据源（PanelController 注入；剪切板功能入口）
    weak var clipboard: ClipboardManager?

    private let engine = SearchEngine()
    private let fileSearch = FileSearchService()
    /// `t ` / `o ` 命令搜索的防抖（250ms 内连续按键只发一次 Spotlight 查询）
    private var commandWorkItem: DispatchWorkItem?
    /// 命令搜索代次：过期回调直接丢弃
    private var commandGeneration = 0
    /// 数据库剪切板搜索代次：输入变化后过期回调直接丢弃
    private var clipboardGeneration = 0

    /// 面板每次显示时调用：切换模式、清空搜索框（打开即干净面板）、刷新焦点与索引
    func prepare(mode: SearchMode) {
        searchMode = mode
        commandWorkItem?.cancel()
        fileSearch.cancel()
        selectedID = nil
        if query.isEmpty {
            // 空查询不触发 didSet，直接刷新（剪切板模式要立即展示最近历史）
            refresh()
        } else {
            query = ""
        }
        focusToken += 1
        if mode == .all { rescan() }
    }

    /// 后台重扫索引并刷新结果；force=true 用于目录监听触发的强制刷新
    func rescan(force: Bool = false) {
        Task {
            await engine.rescanApps(force: force)
            refresh()
        }
    }

    /// 输入变化入口：命令查询防抖后刷新；普通应用搜索立即刷新
    func scheduleRefresh() {
        commandWorkItem?.cancel()
        let command = Self.parseCommand(query)
        if command != nil {
            fileSearch.cancel()
            results = []
            selectedID = nil
            let work = DispatchWorkItem { [weak self] in self?.refresh() }
            commandWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        } else {
            refresh()
        }
    }

    /// `t <关键字>` → Terminal 打开目录；`o <关键字>` → Finder 打开目录/文件
    static func parseCommand(_ raw: String) -> (mode: CommandMode, keyword: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let commands: [(word: String, mode: CommandMode)] = [
            ("t", .terminal),
            ("terminal", .terminal),
            ("o", .finder),
            ("open", .finder),
        ]
        for command in commands {
            if trimmed == command.word {
                return (command.mode, "")
            }
            let prefix = command.word + " "
            if trimmed.hasPrefix(prefix) {
                return (command.mode, trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    enum CommandMode {
        case terminal
        case finder
    }

    func refresh() {
        // t/o 命令只在普通模式生效，剪切板模式是纯历史搜索
        if searchMode == .all, let command = Self.parseCommand(query) {
            runCommand(command)
            return
        }
        fileSearch.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        var appResults: [SearchResult] = []
        if searchMode == .all, !trimmed.isEmpty {
            appResults = Array(engine.search(query, limit: Self.appResultLimit))
        }
        let clipLimit = trimmed.isEmpty ? ClipboardLimits.browseCount : Self.clipResultLimit
        // 先搜内存缓存（同步、微秒级），数据库结果异步追加
        let clipResults = (clipboard?.searchMemory(trimmed, limit: clipLimit) ?? []).map(Self.makeClipboardResult)
        results = appResults + clipResults
        if !results.contains(where: { $0.id == selectedID }) {
            selectedID = results.first?.id
        }

        guard !trimmed.isEmpty, let clipboard else { return }
        clipboardGeneration += 1
        let generation = clipboardGeneration
        let knownIDs = Set(clipResults.map(\.id))
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        clipboard.searchDatabase(tokens: tokens, limit: clipLimit * 2) { [weak self] items in
            guard let self, self.clipboardGeneration == generation else { return }
            let extras = items
                .filter { !knownIDs.contains("clip:\($0.id)") }
                .prefix(clipLimit)
            guard !extras.isEmpty else { return }
            self.results = appResults + clipResults + extras.map(Self.makeClipboardResult)
            if !self.results.contains(where: { $0.id == self.selectedID }) {
                self.selectedID = self.results.first?.id
            }
        }
    }

    // MARK: - 剪切板结果

    private static func makeClipboardResult(_ item: ClipboardItem) -> SearchResult {
        let kind: ResultKind
        let title: String
        switch item.type {
        case .text:
            kind = .clipboardText
            let line = item.titleLine
            title = line.isEmpty ? "…" : line
        case .image:
            kind = .clipboardImage
            let size = ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file)
            title = String(format: NSLocalizedString("Image · %@", comment: "clipboard image row"), size)
        case .file:
            kind = .clipboardFile
            title = item.titleLine
        }
        return SearchResult(
            id: "clip:\(item.id)",
            title: title,
            alias: "",
            kind: kind,
            appPath: nil,
            settingAnchor: nil,
            symbolName: nil,
            openPath: item.type == .file ? item.filePath : nil,
            clipItem: item
        )
    }

    private func runCommand(_ command: (mode: CommandMode, keyword: String)) {
        guard !command.keyword.isEmpty else {
            results = []
            selectedID = nil
            return
        }
        commandGeneration += 1
        let generation = commandGeneration
        fileSearch.search(
            keyword: command.keyword,
            directoriesOnly: command.mode == .terminal,
            limit: 5
        ) { [weak self] hits in
            guard let self, self.commandGeneration == generation else { return }
            self.results = Self.makeCommandResults(mode: command.mode, hits: hits)
            self.selectedID = self.results.first?.id
        }
    }

    private static func makeCommandResults(mode: CommandMode, hits: [FileSearchService.Hit]) -> [SearchResult] {
        let displayPaths = elidedPaths(hits.map { tildePath($0.path) })
        return zip(hits, displayPaths).map { hit, displayPath in
            switch mode {
            case .terminal:
                return SearchResult(
                    id: "terminal:\(hit.path)",
                    title: String(format: NSLocalizedString("Open in Terminal: %@", comment: "t command"), displayPath),
                    alias: "",
                    kind: .terminal,
                    appPath: nil,
                    settingAnchor: nil,
                    symbolName: nil,
                    openPath: hit.path,
                    clipItem: nil
                )
            case .finder:
                return SearchResult(
                    id: "finder:\(hit.path)",
                    title: String(format: NSLocalizedString("Open in Finder: %@", comment: "o command"), displayPath),
                    alias: "",
                    kind: .finder,
                    appPath: nil,
                    settingAnchor: nil,
                    symbolName: nil,
                    openPath: hit.path,
                    clipItem: nil
                )
            }
        }
    }

    /// /Users/xxx → ~（缩短显示长度）
    static func tildePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// 本批路径的公共目录前缀用 "…" 替代：路径头部往往完全相同，尾部才是区分点。
    /// 前缀截到最后一个 "/"（显示完整组件）；公共部分只剩 "~/" 时不省略
    static func elidedPaths(_ paths: [String]) -> [String] {
        guard paths.count > 1, var prefix = paths.first else { return paths }
        for path in paths.dropFirst() {
            prefix = commonPrefix(prefix, path)
        }
        guard let lastSlash = prefix.lastIndex(of: "/") else { return paths }
        prefix = String(prefix[...lastSlash])
        guard prefix.count > 3 else { return paths }
        return paths.map { "…/" + $0.dropFirst(prefix.count) }
    }

    private static func commonPrefix(_ a: String, _ b: String) -> String {
        var result = ""
        var ai = a.startIndex
        var bi = b.startIndex
        while ai < a.endIndex, bi < b.endIndex, a[ai] == b[bi] {
            result.append(a[ai])
            ai = a.index(after: ai)
            bi = b.index(after: bi)
        }
        return result
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let currentIndex = results.firstIndex { $0.id == selectedID } ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), results.count - 1)
        selectedID = results[nextIndex].id
    }

    /// 激活当前选中项（回车）
    func activateSelected() {
        guard let selectedID,
              let result = results.first(where: { $0.id == selectedID }) else { return }
        onActivate?(result)
    }

    /// 直接激活某条结果（鼠标点击）
    func activate(_ result: SearchResult) {
        onActivate?(result)
    }

    /// Esc 关闭时清空状态，下次打开是干净的面板
    func reset() {
        commandWorkItem?.cancel()
        fileSearch.cancel()
        query = ""
        selectedID = nil
    }
}
