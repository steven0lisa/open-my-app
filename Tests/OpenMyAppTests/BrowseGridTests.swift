import XCTest

/// 空查询浏览态：应用网格的排序与方向键导航
@MainActor
final class BrowseGridTests: XCTestCase {
    private func app(_ title: String) -> SearchResult {
        SearchResult(
            id: "app:/Applications/\(title).app",
            title: title,
            alias: "",
            kind: .application,
            appPath: "/Applications/\(title).app",
            settingAnchor: nil,
            symbolName: nil,
            openPath: nil,
            clipItem: nil
        )
    }

    // MARK: - 排序（使用频次降序，同频次按名称升序）

    func testSortsByUsageDescending() {
        let sorted = SearchEngine.sortByUsage([
            (result: app("Rarely"), usage: 1),
            (result: app("Frequent"), usage: 5),
            (result: app("Middle"), usage: 3),
        ])
        XCTAssertEqual(sorted.map(\.title), ["Frequent", "Middle", "Rarely"])
    }

    func testEqualUsageFallsBackToTitleAscending() {
        let sorted = SearchEngine.sortByUsage([
            (result: app("Zebra"), usage: 2),
            (result: app("Alpha"), usage: 2),
            (result: app("Beta"), usage: 0),
        ])
        XCTAssertEqual(sorted.map(\.title), ["Alpha", "Zebra", "Beta"])
    }

    func testEmptyInputSortsToEmpty() {
        XCTAssertTrue(SearchEngine.sortByUsage([]).isEmpty)
    }

    // MARK: - 网格导航（上下按列数跨行，左右行首/行尾不换行，全部裁剪在界内）

    private let columns = 7

    func testLeftRightMoveByOneWithinRow() {
        XCTAssertEqual(
            LauncherModel.gridNavigationTarget(current: 9, count: 30, dx: 1, dy: 0, columns: columns),
            10
        )
        XCTAssertEqual(
            LauncherModel.gridNavigationTarget(current: 9, count: 30, dx: -1, dy: 0, columns: columns),
            8
        )
    }

    func testLeftAtRowStartAndRightAtRowEndDoNotWrap() {
        // 行首（index 7）再往左不动；行尾（index 13）再往右不动
        XCTAssertEqual(
            LauncherModel.gridNavigationTarget(current: 7, count: 30, dx: -1, dy: 0, columns: columns),
            7
        )
        XCTAssertEqual(
            LauncherModel.gridNavigationTarget(current: 13, count: 30, dx: 1, dy: 0, columns: columns),
            13
        )
    }

    func testUpDownMoveByColumnCount() {
        XCTAssertEqual(
            LauncherModel.gridNavigationTarget(current: 3, count: 30, dx: 0, dy: 1, columns: columns),
            10
        )
        XCTAssertEqual(
            LauncherModel.gridNavigationTarget(current: 10, count: 30, dx: 0, dy: -1, columns: columns),
            3
        )
    }

    func testVerticalMovesClampToBounds() {
        // 首行再往上停在 0；末行再往下停在最后一格
        XCTAssertEqual(
            LauncherModel.gridNavigationTarget(current: 2, count: 30, dx: 0, dy: -1, columns: columns),
            0
        )
        XCTAssertEqual(
            LauncherModel.gridNavigationTarget(current: 27, count: 30, dx: 0, dy: 1, columns: columns),
            29
        )
    }
}
