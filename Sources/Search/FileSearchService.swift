import CoreServices
import Foundation

// macOS 上 NSMetadataQuery 属于 CoreServices；通知常量是字符串全局量，需包成 NSNotification.Name

/// `t ` / `o ` 命令的本地文件搜索：基于 Spotlight 元数据查询（NSMetadataQuery）
/// - 只在 HOME 目录范围内检索，不触碰 TCC 保护区域之外，避免权限弹窗
/// - `limitResults` 让 Spotlight 拿满即停；同时监听增量结果与收集完毕通知
@MainActor
final class FileSearchService: NSObject {
    struct Hit {
        let path: String
        let isDirectory: Bool
    }

    /// 关键字的锚定语义：前导 "/" = 名字必须以关键字开头，尾随 "/" = 必须以关键字结尾。
    /// 如 `t /google` 只搜 google 开头的目录，`t google/` 只搜 google 结尾的
    struct AnchoredKeyword {
        let term: String
        let anchoredStart: Bool
        let anchoredEnd: Bool
    }

    static func parseKeyword(_ raw: String) -> AnchoredKeyword? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var anchoredStart = false
        var anchoredEnd = false
        while text.hasPrefix("/") {
            anchoredStart = true
            text.removeFirst()
        }
        while text.hasSuffix("/") {
            anchoredEnd = true
            text.removeLast()
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return AnchoredKeyword(term: text, anchoredStart: anchoredStart, anchoredEnd: anchoredEnd)
    }

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var finished = true

    func cancel() {
        guard let query else { return }
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        self.query = nil
        finished = true
    }

    /// completion 在主线程回调且仅回调一次（攒满 limit / 收集完毕 / 超时）
    ///
    /// 分阶段查询保证「完整匹配 > 前缀匹配 > 包含匹配」的排序确定性：
    /// 无锚定时依次发 `==`（完整）→ `BEGINSWITH`（前缀）→ `CONTAINS`（包含）三条
    /// Spotlight 查询，前一级攒满额度即止、不足则进下一级补齐；锚定（/ 前导或尾随）
    /// 时谓词本身语义已完整，单条查询即可。不能只用一条 CONTAINS 查询在内存里排序
    /// ——Spotlight 对 CONTAINS/BEGINSWITH 的返回顺序都不可控，目标目录可能排在
    /// 几百条之外，候选池截断会把完整匹配挤出结果（实测踩过）。
    func search(
        keyword: String,
        directoriesOnly: Bool,
        limit: Int = 5,
        completion: @escaping ([Hit]) -> Void
    ) {
        cancel()
        guard let parsed = Self.parseKeyword(keyword) else {
            completion([])
            return
        }

        let anchored = parsed.anchoredStart || parsed.anchoredEnd
        var baseClauses = ["NOT kMDItemFSName BEGINSWITH '.'"]
        if directoriesOnly {
            // 目录，排除 .app 等包（打开包目录在 Terminal 里没有意义）
            baseClauses.insert(
                "(kMDItemContentTypeTree == 'public.folder' OR kMDItemContentTypeTree == 'public.directory') AND NOT (kMDItemContentTypeTree == 'com.apple.application-bundle')",
                at: 0
            )
        }
        func makePredicate(nameClause: String, arguments: [String]) -> NSPredicate {
            NSPredicate(
                format: ([nameClause] + baseClauses).joined(separator: " AND "),
                argumentArray: arguments
            )
        }

        finished = false
        var tierHits: [[Hit]] = [[], [], []]  // 0 完整 / 1 前缀 / 2 包含

        func dropCurrentQuery() {
            query?.stop()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            query = nil
        }

        func complete() {
            guard !finished else { return }
            finished = true
            dropCurrentQuery()
            completion(Array(tierHits.flatMap { $0 }.prefix(limit)))
        }

        // 增量结果的三个来源（缺一不可，实测）：
        // - GatheringProgress：gathering 期间的批次结果（最主要的提前停止依据）
        // - DidUpdate：gathering 完成后索引变化（live query）
        // - DidFinishGathering：收集完成
        // 注意：增量通知的真名是 NSMetadataQueryDidUpdate（不是 ...UpdateNotification，
        // 手写字符串差一个 "Did" 永远不触发，实测踩过）
        func installObservers(
            on current: NSMetadataQuery,
            collectHandler: @escaping (Notification) -> Void,
            gatherFinished: @escaping () -> Void
        ) {
            let center = NotificationCenter.default
            observers.append(
                center.addObserver(
                    forName: .NSMetadataQueryGatheringProgress,
                    object: current,
                    queue: .main,
                    using: collectHandler
                )
            )
            observers.append(
                center.addObserver(
                    forName: .NSMetadataQueryDidUpdate,
                    object: current,
                    queue: .main,
                    using: collectHandler
                )
            )
            observers.append(
                center.addObserver(
                    forName: .NSMetadataQueryDidFinishGathering,
                    object: current,
                    queue: .main
                ) { _ in
                    gatherFinished()
                }
            )
        }

        /// 依次跑三个匹配级别；攒满 limit 提前收工，不足则进下一级。
        /// 锚定查询只有一级（级别 3 的单查询），无锚定从级别 0 开始
        func startPhase(_ level: Int) {
            guard !finished else { return }
            let already = tierHits.reduce(0) { $0 + $1.count }
            if level > 2 || already >= limit {
                complete()
                return
            }
            dropCurrentQuery()
            let current = NSMetadataQuery()
            current.searchScopes = [NSHomeDirectory()]
            let budget = limit - already
            let nameClause: String
            let arguments: [String]
            switch level {
            case 0:
                // 无锚定的完整匹配级别
                nameClause = "kMDItemFSName ==[cd] %@"
                arguments = [parsed.term]
            case 1:
                nameClause = "kMDItemFSName BEGINSWITH[cd] %@"
                arguments = [parsed.term]
            case 2:
                nameClause = "kMDItemFSName CONTAINS[cd] %@"
                arguments = [parsed.term]
            default:
                // 锚定语义：BEGINSWITH / ENDSWITH / 两者组合，单查询即完整语义
                nameClause = Self.anchoredNameClause(parsed: parsed)
                arguments = [parsed.term, parsed.term]
            }
            current.predicate = makePredicate(nameClause: nameClause, arguments: arguments)
            let excluding = Set(tierHits.flatMap { $0 }.map(\.path))
            let handler: (Notification) -> Void = { _ in
                let hits = Self.collect(current, limit: budget, excluding: excluding)
                // 锚定单查询（level 3）没有分级语义，结果存进第一个 tier 即可
                tierHits[level == 3 ? 0 : level] = hits
                if hits.count >= budget {
                    complete()
                }
            }
            installObservers(on: current, collectHandler: handler) {
                startPhase(anchored ? 99 : level + 1)
            }
            query = current
            current.start()
        }

        startPhase(anchored ? 3 : 0)
        // 超时兜底：索引未就绪时查询可能长时间无通知；带着已有结果收工
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.query != nil else { return }
            complete()
        }
    }

    /// 锚定关键字对应的单查询谓词（BEGINSWITH / ENDSWITH / 组合）。internal 供单元测试
    static func anchoredNameClause(parsed: AnchoredKeyword) -> String {
        switch (parsed.anchoredStart, parsed.anchoredEnd) {
        case (true, true):
            return "(kMDItemFSName BEGINSWITH[cd] %@ AND kMDItemFSName ENDSWITH[cd] %@)"
        case (true, false):
            return "kMDItemFSName BEGINSWITH[cd] %@"
        case (false, true):
            return "kMDItemFSName ENDSWITH[cd] %@"
        case (false, false):
            return "kMDItemFSName CONTAINS[cd] %@"
        }
    }

    /// 常见依赖库 / 构建产物目录名：结果路径中出现任一组件（"/<name>/"）即跳过。
    /// kMDItemPath 在谓词中不受支持，这类过滤只能内存侧做
    private static let excludedDirectoryNames: Set<String> = [
        // JS / 前端
        "node_modules", "bower_components", ".next", ".nuxt", ".output", ".parcel-cache",
        // Swift / Apple
        "DerivedData", ".build", ".swiftpm", "Pods", "Carthage", ".packages",
        // Rust / C / Go
        "target", "vendor",
        // Python
        "__pycache__", ".venv", "venv", "site-packages", ".pytest_cache", ".mypy_cache", ".tox",
        // 通用构建产物与版本库
        "build", "dist", "coverage", ".cache", ".git", ".gradle", ".terraform",
    ]

    /// 路径中是否包含被排除的目录组件
    private static func isExcludedPath(_ path: String) -> Bool {
        for name in excludedDirectoryNames {
            if path.contains("/\(name)/") {
                return true
            }
        }
        return false
    }

    private static func collect(_ query: NSMetadataQuery, limit: Int, excluding: Set<String> = []) -> [Hit] {
        // kMDItemPath 在谓词中不受支持（会被静默忽略，实测踩过），Library / 依赖目录排除只能在内存侧做
        let libraryPrefix = NSHomeDirectory() + "/Library/"
        var hits: [Hit] = []
        for item in query.results {
            if hits.count >= limit { break }
            guard let metadata = item as? NSMetadataItem,
                  let path = metadata.value(forAttribute: kMDItemPath as String) as? String else {
                continue
            }
            if path.hasPrefix(libraryPrefix) { continue }
            if isExcludedPath(path) { continue }
            if excluding.contains(path) { continue }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            hits.append(Hit(path: path, isDirectory: isDirectory.boolValue))
        }
        return hits
    }
}
