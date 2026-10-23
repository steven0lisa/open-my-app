import XCTest
@testable import OpenMyApp

/// 剪切板清理的删留边界：临时 SQLite 库上验证「超过保留天数 且 使用次数 < 阈值」组合。
/// 参数显式传入 cleanupOld，不读 Preferences（避免环境 defaults 干扰）
final class ClipboardStoreCleanupTests: XCTestCase {
    private var directory: URL!
    private var store: ClipboardStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oma-cleanup-tests-\(UUID().uuidString)", isDirectory: true)
        store = ClipboardStore(directory: directory)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func insert(_ text: String, daysAgo: Double, uses: Int, now: Date = Date()) throws {
        let record = ClipboardStore.NewRecord(
            type: .text,
            preview: text,
            content: text,
            filePath: nil,
            thumbPath: nil,
            byteSize: text.utf8.count,
            searchText: text,
            hash: UUID().uuidString,
            createdAt: now.addingTimeInterval(-daysAgo * 24 * 3600)
        )
        let id = store.upsert(record).id
        for _ in 0..<uses { store.recordUse(id: id) }
    }

    private func storedTexts() -> [String] {
        store.recentItems(limit: 100).map(\.preview)
    }

    func testDefaultParametersMatchProductSemantics() throws {
        // 默认 21 天 / 2 次：超过 21 天且使用 <2 删，其余保留
        try insert("old-unused", daysAgo: 25, uses: 0)
        try insert("old-once", daysAgo: 25, uses: 1)
        try insert("old-twice", daysAgo: 25, uses: 2)
        try insert("recent-unused", daysAgo: 5, uses: 0)
        try insert("old-thrice", daysAgo: 25, uses: 3)

        let removed = store.cleanupOld(
            now: Date(),
            retentionDays: 21,
            keepUsageCount: 2
        )

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(
            Set(storedTexts()),
            ["old-twice", "recent-unused", "old-thrice"]
        )
    }

    func testCustomParameters() throws {
        // 自定义 7 天 / 1 次：超过 7 天且使用 0 次才删（使用过 1 次即保留）
        try insert("week-old-unused", daysAgo: 8, uses: 0)
        try insert("week-old-once", daysAgo: 8, uses: 1)
        try insert("week-fresh", daysAgo: 2, uses: 0)

        let removed = store.cleanupOld(
            now: Date(),
            retentionDays: 7,
            keepUsageCount: 1
        )

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(Set(storedTexts()), ["week-old-once", "week-fresh"])
    }

    func testRemovedRecordsLeaveNoTraceInSearchIndex() throws {
        try insert("victim content alpha", daysAgo: 40, uses: 0)
        try insert("survivor content beta", daysAgo: 40, uses: 5)
        guard store.ftsAvailable else {
            throw XCTSkip("系统 SQLite 无 FTS5，跳过索引残留检查")
        }

        _ = store.cleanupOld(now: Date(), retentionDays: 21, keepUsageCount: 2)

        let hits = store.search(tokens: ["alpha"], limit: 10)
        XCTAssertTrue(hits.isEmpty, "被清理记录不应残留在 FTS 索引")
        let kept = store.search(tokens: ["beta"], limit: 10)
        XCTAssertEqual(kept.map(\.preview), ["survivor content beta"])
    }
}
