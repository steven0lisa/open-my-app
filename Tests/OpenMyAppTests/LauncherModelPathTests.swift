import XCTest

/// 结果行路径展示工具：~ 缩写与公共前缀省略
@MainActor
final class LauncherModelPathTests: XCTestCase {
    func testTildePathAbbreviatesHomePrefix() {
        XCTAssertEqual(LauncherModel.tildePath(NSHomeDirectory() + "/work/x"), "~/work/x")
        XCTAssertEqual(LauncherModel.tildePath(NSHomeDirectory()), "~")
        XCTAssertEqual(LauncherModel.tildePath("/usr/local"), "/usr/local")
    }

    func testElidedPathsReplacesCommonDirectoryPrefix() {
        let elided = LauncherModel.elidedPaths([
            "/home/u/work/aaa/one",
            "/home/u/work/aaa/two",
        ])
        XCTAssertEqual(elided, ["…/one", "…/two"])
    }

    func testElidedPathsKeepsSinglePathIntact() {
        let paths = ["/home/u/work/only"]
        XCTAssertEqual(LauncherModel.elidedPaths(paths), paths)
    }

    func testElidedPathsKeepsShortCommonPrefixIntact() {
        // 公共前缀截到最后一个 "/" 后 ≤3 字符时不省略（省了反而不省空间）
        let paths = ["/x/aaa", "/x/bbb"]
        XCTAssertEqual(LauncherModel.elidedPaths(paths), paths)
    }

    func testElidedPathsKeepsUnrelatedPathsIntact() {
        let paths = ["/aaa", "/bbb"]
        XCTAssertEqual(LauncherModel.elidedPaths(paths), paths)
    }
}
