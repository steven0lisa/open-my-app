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
    func search(
        keyword: String,
        directoriesOnly: Bool,
        limit: Int = 5,
        completion: @escaping ([Hit]) -> Void
    ) {
        cancel()
        let keyword = keyword.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else {
            completion([])
            return
        }

        let query = NSMetadataQuery()
        query.searchScopes = [NSHomeDirectory()]

        var clauses = [
            "kMDItemFSName CONTAINS[cd] %@",
            "NOT kMDItemFSName BEGINSWITH '.'",
        ]
        if directoriesOnly {
            // 目录，排除 .app 等包（打开包目录在 Terminal 里没有意义）
            clauses.insert(
                "(kMDItemContentTypeTree == 'public.folder' OR kMDItemContentTypeTree == 'public.directory') AND NOT (kMDItemContentTypeTree == 'com.apple.application-bundle')",
                at: 0
            )
        }
        query.predicate = NSPredicate(format: clauses.joined(separator: " AND "), keyword)

        finished = false
        var hits: [Hit] = []
        let center = NotificationCenter.default

        func finish() {
            guard !finished else { return }
            finished = true
            // 兜底收集：DidFinish 触发时可能从未走过增量收集
            hits = Self.collect(query, limit: limit)
            query.stop()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            self.query = nil
            completion(hits)
        }

        // 增量结果的三个来源（缺一不可，实测）：
        // - GatheringProgress：gathering 期间的批次结果（最主要的提前停止依据）
        // - DidUpdate：gathering 完成后索引变化（live query）
        // - DidFinishGathering：收集完成，finish 内兜底收集
        // 注意：增量通知的真名是 NSMetadataQueryDidUpdate（不是 ...UpdateNotification，
        // 手写字符串差一个 "Did" 永远不触发，实测踩过）
        let collectHandler: (Notification) -> Void = { _ in
            hits = Self.collect(query, limit: limit)
            if hits.count >= limit {
                finish()
            }
        }
        observers.append(
            center.addObserver(
                forName: .NSMetadataQueryGatheringProgress,
                object: query,
                queue: .main,
                using: collectHandler
            )
        )
        observers.append(
            center.addObserver(
                forName: .NSMetadataQueryDidUpdate,
                object: query,
                queue: .main,
                using: collectHandler
            )
        )
        observers.append(
            center.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { _ in
                finish()
            }
        )
        // 超时兜底：索引未就绪时查询可能长时间无通知
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if self?.query === query {
                finish()
            }
        }

        query.start()
        self.query = query
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

    private static func collect(_ query: NSMetadataQuery, limit: Int) -> [Hit] {
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
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            hits.append(Hit(path: path, isDirectory: isDirectory.boolValue))
        }
        return hits
    }
}
