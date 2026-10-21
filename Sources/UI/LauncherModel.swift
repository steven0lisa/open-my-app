import Foundation

/// 搜索框视图模型：持有查询状态与结果列表，桥接 SearchEngine 与 UI
@MainActor
final class LauncherModel: ObservableObject {
    /// focusToken 变化用于在面板重新显示时让输入框重新获得焦点
    @Published var focusToken = 0
    @Published var query: String = "" {
        didSet {
            if query != oldValue { refresh() }
        }
    }
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedID: String?

    var onActivate: ((SearchResult) -> Void)?
    var onOpenSettings: (() -> Void)?

    private let engine = SearchEngine()

    /// 面板每次显示时调用：重扫应用目录 + 刷新焦点
    func prepare() {
        focusToken += 1
        rescan()
    }

    /// 后台重扫索引并刷新结果；force=true 用于目录监听触发的强制刷新
    func rescan(force: Bool = false) {
        Task {
            await engine.rescanApps(force: force)
            refresh()
        }
    }

    func refresh() {
        results = engine.search(query)
        if results.contains(where: { $0.id == selectedID }) { return }
        selectedID = results.first?.id
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
        query = ""
        selectedID = nil
    }
}
