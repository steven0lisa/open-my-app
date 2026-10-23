import XCTest

/// 目录搜索关键字的 `/` 锚定解析与锚定谓词映射
/// （FileSearchService 为 @MainActor，静态成员随之隔离）
@MainActor
final class FileSearchServiceTests: XCTestCase {
    private func assertKeyword(
        _ raw: String,
        term: String?,
        start: Bool = false,
        end: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let term else {
            XCTAssertNil(
                FileSearchService.parseKeyword(raw),
                "期望 \(raw) 解析为 nil，但有结果",
                file: file,
                line: line
            )
            return
        }
        guard let parsed = FileSearchService.parseKeyword(raw) else {
            XCTFail("期望 \(raw) 解析出关键字 \(term)，但为 nil", file: file, line: line)
            return
        }
        XCTAssertEqual(parsed.term, term, "关键字错误: \(raw)", file: file, line: line)
        XCTAssertEqual(parsed.anchoredStart, start, "前锚定错误: \(raw)", file: file, line: line)
        XCTAssertEqual(parsed.anchoredEnd, end, "后锚定错误: \(raw)", file: file, line: line)
    }

    func testUnanchoredKeyword() {
        assertKeyword("google", term: "google")
        assertKeyword("  google  ", term: "google")
    }

    func testStartAnchored() {
        assertKeyword("/google", term: "google", start: true)
    }

    func testEndAnchored() {
        assertKeyword("google/", term: "google", end: true)
    }

    func testBothAnchored() {
        assertKeyword("/google/", term: "google", start: true, end: true)
    }

    func testRepeatedSlashesCollapse() {
        assertKeyword("//google//", term: "google", start: true, end: true)
        assertKeyword("google//", term: "google", end: true)
    }

    func testSlashOnlyOrBlankReturnsNil() {
        assertKeyword("/", term: nil)
        assertKeyword("//", term: nil)
        assertKeyword("", term: nil)
        assertKeyword("   ", term: nil)
        assertKeyword("  /  /  ", term: nil)
    }

    func testAnchoredNameClauses() {
        func clause(_ start: Bool, _ end: Bool) -> String {
            FileSearchService.anchoredNameClause(
                parsed: FileSearchService.AnchoredKeyword(term: "x", anchoredStart: start, anchoredEnd: end)
            )
        }
        XCTAssertEqual(clause(true, false), "kMDItemFSName BEGINSWITH[cd] %@")
        XCTAssertEqual(clause(false, true), "kMDItemFSName ENDSWITH[cd] %@")
        XCTAssertEqual(
            clause(true, true),
            "(kMDItemFSName BEGINSWITH[cd] %@ AND kMDItemFSName ENDSWITH[cd] %@)"
        )
    }

    // MARK: - 档位内浅目录优先

    func testSortByShallowPathPrefersFewerComponents() {
        let hits = [
            FileSearchService.Hit(path: "/Users/u/work/deep/deeper/work", isDirectory: true),
            FileSearchService.Hit(path: "/Users/u/work", isDirectory: true),
            FileSearchService.Hit(path: "/Users/u/a/b/work", isDirectory: true),
        ]
        XCTAssertEqual(
            FileSearchService.sortByShallowPath(hits).map(\.path),
            [
                "/Users/u/work",
                "/Users/u/a/b/work",
                "/Users/u/work/deep/deeper/work",
            ]
        )
    }

    func testSortByShallowPathKeepsOriginalOrderForSameDepth() {
        let hits = [
            FileSearchService.Hit(path: "/Users/u/aa", isDirectory: true),
            FileSearchService.Hit(path: "/Users/u/bb", isDirectory: true),
            FileSearchService.Hit(path: "/Users/u/cc", isDirectory: true),
        ]
        XCTAssertEqual(FileSearchService.sortByShallowPath(hits).map(\.path), hits.map(\.path))
    }

    func testSortByShallowPathKeepsEmptyInputIntact() {
        XCTAssertTrue(FileSearchService.sortByShallowPath([]).isEmpty)
    }
}
