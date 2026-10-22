import Foundation
import SQLite3
import CryptoKit

/// 剪切板历史的 SQLite 存储。
/// 线程模型：所有公开方法内部经串行 queue 同步执行，可从任意线程调用（搜索由
/// ClipboardManager 派发到后台队列，不会阻塞主线程）。
/// 大字段策略：>16KB 文本与图片不进 DB，只存文件路径引用；全文搜索靠 FTS5
/// 倒排索引（trigram 分词，支持任意子串与中文），DB 列里只留 preview 小字段。
final class ClipboardStore {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.openmyapp.clipboard.store")
    /// false = 系统 SQLite 无 FTS5，搜索退化为 LIKE 全扫（仅能命中 preview/content/路径）
    private(set) var ftsAvailable = false

    struct NewRecord {
        let type: ClipboardItem.ItemType
        let preview: String
        let content: String?
        let filePath: String?
        let thumbPath: String?
        let byteSize: Int
        /// 全文检索文本：文本=全文（含大文本，捕获时在内存中）、文件=路径、图片=nil（不参与关键字搜索）
        let searchText: String?
        let hash: String
        let createdAt: Date
    }

    private static let columns = "id, type, preview, content, file_path, thumb_path, byte_size, use_count, created_at, last_used_at"
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("clipboard.sqlite3").path
        if sqlite3_open_v2(
            path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) != SQLITE_OK {
            NSLog("[OpenMyApp] 剪切板数据库打开失败: \(path)")
            if let db { sqlite3_close(db) }
            db = nil
            return
        }
        // WAL：后台搜索读与捕获写可并行
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("""
        CREATE TABLE IF NOT EXISTS clip_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type INTEGER NOT NULL,
            preview TEXT NOT NULL DEFAULT '',
            content TEXT,
            file_path TEXT,
            thumb_path TEXT,
            byte_size INTEGER NOT NULL DEFAULT 0,
            content_hash TEXT NOT NULL,
            use_count INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            last_used_at REAL
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_clip_created ON clip_items(created_at)")
        exec("CREATE INDEX IF NOT EXISTS idx_clip_hash ON clip_items(content_hash)")
        // trigram 分词：任意 ≥3 字符子串可走索引，大小写不敏感（ASCII 折叠），中文按字符切
        ftsAvailable = exec("CREATE VIRTUAL TABLE IF NOT EXISTS clip_fts USING fts5(search_text, tokenize='trigram')")
        if !ftsAvailable {
            NSLog("[OpenMyApp] 系统 SQLite 无 FTS5，剪切板全文搜索退化为 LIKE 扫描")
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - 写入

    /// 内容去重写入：同 hash 已存在则刷新 created_at 置顶（use_count 保留），返回 (id, 是否新记录)
    func upsert(_ record: NewRecord) -> (id: Int64, isNew: Bool) {
        queue.sync {
            guard let db else { return (0, false) }
            var existing: Int64?
            query("SELECT id FROM clip_items WHERE content_hash = ?", bind: { stmt in
                bindText(stmt, 1, record.hash)
            }, map: { stmt in sqlite3_column_int64(stmt, 0) }).forEach { existing = $0 }

            if let id = existing {
                update("UPDATE clip_items SET created_at = ? WHERE id = ?", bind: { stmt in
                    sqlite3_bind_double(stmt, 1, record.createdAt.timeIntervalSince1970)
                    sqlite3_bind_int64(stmt, 2, id)
                })
                return (id, false)
            }

            update("INSERT INTO clip_items (type, preview, content, file_path, thumb_path, byte_size, content_hash, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", bind: { stmt in
                sqlite3_bind_int64(stmt, 1, Int64(record.type.rawValue))
                bindText(stmt, 2, record.preview)
                bindText(stmt, 3, record.content)
                bindText(stmt, 4, record.filePath)
                bindText(stmt, 5, record.thumbPath)
                sqlite3_bind_int64(stmt, 6, Int64(record.byteSize))
                bindText(stmt, 7, record.hash)
                sqlite3_bind_double(stmt, 8, record.createdAt.timeIntervalSince1970)
            })
            let id = sqlite3_last_insert_rowid(db)
            if ftsAvailable, let text = record.searchText, !text.isEmpty {
                update("INSERT INTO clip_fts (rowid, search_text) VALUES (?, ?)", bind: { stmt in
                    sqlite3_bind_int64(stmt, 1, id)
                    bindText(stmt, 2, text)
                })
            }
            return (id, true)
        }
    }

    /// 选中即计数：use_count +1 并刷新 last_used_at
    func recordUse(id: Int64, at: Date = Date()) {
        queue.sync {
            update("UPDATE clip_items SET use_count = use_count + 1, last_used_at = ? WHERE id = ?", bind: { stmt in
                sqlite3_bind_double(stmt, 1, at.timeIntervalSince1970)
                sqlite3_bind_int64(stmt, 2, id)
            })
        }
    }

    /// 外部数据源导入（如从其他剪切板管理器迁移）：同 hash 去重时
    /// created_at 取两者较新（最近一次复制时间才真实）、use_count 累加（两个工具的使用都算数，
    /// 也避免低 use_count 的历史记录导入当天就被每日清理误删）。
    /// 返回 (id, 是否新插入)
    @discardableResult
    func importRecord(_ record: NewRecord, useCount: Int) -> (id: Int64, inserted: Bool) {
        queue.sync {
            guard let db else { return (0, false) }
            var existing: (id: Int64, createdAt: Double)?
            query("SELECT id, created_at FROM clip_items WHERE content_hash = ?", bind: { stmt in
                bindText(stmt, 1, record.hash)
            }, map: { stmt in
                (sqlite3_column_int64(stmt, 0), sqlite3_column_double(stmt, 1))
            }).forEach { existing = $0 }

            let importTime = record.createdAt.timeIntervalSince1970
            if let existing {
                update("UPDATE clip_items SET created_at = MAX(created_at, ?), use_count = use_count + ? WHERE id = ?", bind: { stmt in
                    sqlite3_bind_double(stmt, 1, importTime)
                    sqlite3_bind_int64(stmt, 2, Int64(useCount))
                    sqlite3_bind_int64(stmt, 3, existing.id)
                })
                return (existing.id, false)
            }

            update("INSERT INTO clip_items (type, preview, content, file_path, thumb_path, byte_size, content_hash, use_count, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", bind: { stmt in
                sqlite3_bind_int64(stmt, 1, Int64(record.type.rawValue))
                bindText(stmt, 2, record.preview)
                bindText(stmt, 3, record.content)
                bindText(stmt, 4, record.filePath)
                bindText(stmt, 5, record.thumbPath)
                sqlite3_bind_int64(stmt, 6, Int64(record.byteSize))
                bindText(stmt, 7, record.hash)
                sqlite3_bind_int64(stmt, 8, Int64(useCount))
                sqlite3_bind_double(stmt, 9, importTime)
            })
            let id = sqlite3_last_insert_rowid(db)
            if ftsAvailable, let text = record.searchText, !text.isEmpty {
                update("INSERT INTO clip_fts (rowid, search_text) VALUES (?, ?)", bind: { stmt in
                    sqlite3_bind_int64(stmt, 1, id)
                    bindText(stmt, 2, text)
                })
            }
            return (id, true)
        }
    }

    // MARK: - 读取

    /// 最近记录（新→旧），启动装载内存缓存与剪切板模式空查询浏览共用
    func recentItems(limit: Int) -> [ClipboardItem] {
        queue.sync {
            query(
                "SELECT \(Self.columns) FROM clip_items ORDER BY created_at DESC, id DESC LIMIT ?",
                bind: { sqlite3_bind_int64($0, 1, Int64(limit)) },
                map: Self.item(from:)
            )
        }
    }

    /// 关键字搜索：全部词元按 AND 匹配、不分大小写。
    /// 词元均 ≥3 字符且 FTS5 可用时走倒排索引（覆盖大文本全文）；否则退化为
    /// LIKE 扫描小字段（preview / content / file_path，SQLite lower 与 LIKE 均对 ASCII 折叠大小写）。
    /// 注意按字符数而非 UTF-8 字节数判断：中文 2 字 = 6 字节，字节数会误入 trigram
    /// 路径（trigram 需要 ≥3 字符才能成块，2 字短语永远匹配不上）。
    /// 大文本的短词（1~2 字符）查询只能命中 preview 前 200 字符，属可接受取舍。
    func search(tokens: [String], limit: Int) -> [ClipboardItem] {
        let tokens = tokens.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return recentItems(limit: limit) }
        return queue.sync {
            if ftsAvailable, tokens.allSatisfy({ $0.count >= 3 }) {
                // trigram 短语 = 任意位置子串匹配；引号会破坏 MATCH 语法，直接剔除
                let match = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
                    .joined(separator: " AND ")
                // MATCH 语法非法（如纯符号词元）时 query 记日志并返回空，交由上层空结果兜底
                return query("""
                    SELECT \(Self.columns) FROM clip_items ci
                    JOIN clip_fts ON clip_fts.rowid = ci.id
                    WHERE clip_fts MATCH ?
                    ORDER BY ci.created_at DESC, ci.id DESC LIMIT ?
                    """, bind: { stmt in
                        bindText(stmt, 1, match)
                        sqlite3_bind_int64(stmt, 2, Int64(limit))
                    }, map: Self.item(from:))
            }
            var clauses: [String] = []
            var patterns: [String] = []
            for token in tokens {
                clauses.append("(IFNULL(preview,'') LIKE ? ESCAPE '\\' OR IFNULL(content,'') LIKE ? ESCAPE '\\' OR IFNULL(file_path,'') LIKE ? ESCAPE '\\')")
                let pattern = "%\(Self.likeEscaped(token))%"
                patterns.append(pattern)
            }
            let sql = """
            SELECT \(Self.columns) FROM clip_items
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY created_at DESC, id DESC LIMIT ?
            """
            return query(sql, bind: { stmt in
                for (i, pattern) in patterns.enumerated() {
                    bindText(stmt, Int32(i * 3 + 1), pattern)
                    bindText(stmt, Int32(i * 3 + 2), pattern)
                    bindText(stmt, Int32(i * 3 + 3), pattern)
                }
                sqlite3_bind_int64(stmt, Int32(patterns.count * 3 + 1), Int64(limit))
            }, map: Self.item(from:))
        }
    }

    // MARK: - 清理

    /// 每日清理：创建于 1 周 ~ 3 周窗口内且使用次数 <2 的记录删除（含落盘文件与 FTS 索引行）。
    /// 熬过 3 周的记录必然使用过 ≥2 次，永久保留。
    func cleanupOld(now: Date = Date()) -> Int {
        let windowStart = now.addingTimeInterval(-21 * 24 * 3600).timeIntervalSince1970
        let windowEnd = now.addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970
        return queue.sync {
            guard db != nil else { return 0 }
            var removed = 0
            while true {
                let victims: [(id: Int64, filePath: String?, thumbPath: String?)] = query(
                    "SELECT id, file_path, thumb_path FROM clip_items WHERE use_count < 2 AND created_at < ? AND created_at > ? LIMIT 500",
                    bind: { stmt in
                        sqlite3_bind_double(stmt, 1, windowEnd)
                        sqlite3_bind_double(stmt, 2, windowStart)
                    },
                    map: { stmt in
                        (sqlite3_column_int64(stmt, 0), Self.text(stmt, 1), Self.text(stmt, 2))
                    }
                )
                guard !victims.isEmpty else { break }
                for victim in victims {
                    if let path = victim.filePath { try? FileManager.default.removeItem(atPath: path) }
                    if let path = victim.thumbPath { try? FileManager.default.removeItem(atPath: path) }
                    if ftsAvailable {
                        update("DELETE FROM clip_fts WHERE rowid = ?", bind: {
                            sqlite3_bind_int64($0, 1, victim.id)
                        })
                    }
                    update("DELETE FROM clip_items WHERE id = ?", bind: {
                        sqlite3_bind_int64($0, 1, victim.id)
                    })
                }
                removed += victims.count
                if victims.count < 500 { break }
            }
            if removed > 0 {
                NSLog("[OpenMyApp] 剪切板清理: 删除 \(removed) 条低频旧记录")
            }
            return removed
        }
    }

    /// 测试与诊断用
    func itemCount() -> Int {
        queue.sync {
            query("SELECT COUNT(*) FROM clip_items", bind: { _ in }, map: { Int(sqlite3_column_int64($0, 0)) }).first ?? 0
        }
    }

    // MARK: - 内容哈希

    /// 去重键：类型前缀 + 原始字节（文本/图片按内容、文件按路径）
    static func contentHash(_ kind: String, _ payload: Data) -> String {
        var data = Data(kind.utf8)
        data.append(payload)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - SQLite 底层

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            if let error {
                NSLog("[OpenMyApp] sqlite exec 失败: \(String(cString: error)) sql=\(sql.prefix(80))")
                sqlite3_free(error)
            }
            return false
        }
        return true
    }

    private func update(_ sql: String, bind: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            NSLog("[OpenMyApp] sqlite prepare 失败: \(sql.prefix(80))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        if sqlite3_step(stmt) != SQLITE_DONE {
            NSLog("[OpenMyApp] sqlite step 失败: \(sql.prefix(80))")
        }
    }

    private func query<T>(_ sql: String, bind: (OpaquePointer) -> Void, map: (OpaquePointer) -> T?) -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            NSLog("[OpenMyApp] sqlite prepare 失败: \(sql.prefix(80))")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var result: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let value = map(stmt) { result.append(value) }
        }
        return result
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private static func item(from stmt: OpaquePointer) -> ClipboardItem? {
        guard let type = ClipboardItem.ItemType(rawValue: Int(sqlite3_column_int64(stmt, 1))) else { return nil }
        return ClipboardItem(
            id: sqlite3_column_int64(stmt, 0),
            type: type,
            preview: text(stmt, 2) ?? "",
            content: text(stmt, 3),
            filePath: text(stmt, 4),
            thumbPath: text(stmt, 5),
            byteSize: Int(sqlite3_column_int64(stmt, 6)),
            useCount: Int(sqlite3_column_int64(stmt, 7)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
        )
    }

    private static func likeEscaped(_ token: String) -> String {
        token
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
