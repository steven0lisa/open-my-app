import XCTest

/// 「命令词 + 空格 + 关键字」解析：内置 t/terminal、o/open 与自定义前缀（含唯一缩写）
final class CommandRouterTests: XCTestCase {
    private func command(
        _ prefix: String,
        name: String = "App",
        path: String = "/Applications/App.app"
    ) -> CustomAppCommand {
        CustomAppCommand(id: UUID(), prefix: prefix, appName: name, appPath: path)
    }

    private func assertParse(
        _ raw: String,
        custom: [CustomAppCommand] = [],
        mode expectedMode: CommandMode?,
        keyword expectedKeyword: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let parsed = CommandRouter.parse(raw, custom: custom)
        if expectedMode == nil {
            XCTAssertNil(parsed, "期望 \(raw) 不是命令，但解析出了结果", file: file, line: line)
            return
        }
        XCTAssertNotNil(parsed, "期望 \(raw) 是命令，但解析为 nil", file: file, line: line)
        XCTAssertEqual(parsed?.mode, expectedMode, "命令类型错误: \(raw)", file: file, line: line)
        XCTAssertEqual(parsed?.keyword, expectedKeyword, "关键字错误: \(raw)", file: file, line: line)
    }

    // MARK: - 内置命令词

    func testBuiltinWordsParse() {
        assertParse("t webapp", mode: .terminal, keyword: "webapp")
        assertParse("terminal webapp", mode: .terminal, keyword: "webapp")
        assertParse("o note", mode: .finder, keyword: "note")
        assertParse("open note", mode: .finder, keyword: "note")
    }

    func testBuiltinWordWithoutKeywordEntersCommandMode() {
        assertParse("t", mode: .terminal)
        assertParse("t ", mode: .terminal)
        assertParse("open", mode: .finder)
    }

    func testNonCommandsFallThroughToAppSearch() {
        assertParse("webapp", mode: nil)
        assertParse("", mode: nil)
        // 完整词的前缀不误触（防 "opened"）
        assertParse("opened x", mode: nil)
        assertParse("terminus x", mode: nil)
    }

    func testKeywordMayContainSpaces() {
        assertParse("t webapp adhoc", mode: .terminal, keyword: "webapp adhoc")
        assertParse("t  double space", mode: .terminal, keyword: "double space")
    }

    func testCaseInsensitive() {
        assertParse("T Webapp", mode: .terminal, keyword: "Webapp")
        assertParse("Terminal x", mode: .terminal, keyword: "x")
        assertParse("OPEN note", mode: .finder, keyword: "note")
    }

    // MARK: - 自定义前缀

    func testCustomPrefixExactMatch() {
        let zcode = command("zcode", name: "Zed", path: "/Applications/Zed.app")
        assertParse("zcode proj", custom: [zcode], mode: .customApp(zcode), keyword: "proj")
        assertParse("zcode", custom: [zcode], mode: .customApp(zcode))
        assertParse("ZCODE proj", custom: [zcode], mode: .customApp(zcode), keyword: "proj")
    }

    func testUniqueAbbreviationTriggers() {
        let zcode = command("zcode", name: "Zed", path: "/Applications/Zed.app")
        assertParse("z proj", custom: [zcode], mode: .customApp(zcode), keyword: "proj")
        assertParse("zc proj", custom: [zcode], mode: .customApp(zcode), keyword: "proj")
    }

    func testBareAbbreviationDoesNotHijackAppSearch() {
        // 裸缩写不带关键字：仍走普通 app 搜索（配置 zcode 后输入 z 也要能搜 z 开头的应用）
        assertParse("z", custom: [command("zcode", name: "Zed", path: "/Applications/Zed.app")], mode: nil)
    }

    func testAmbiguousAbbreviationFallsBackToAppSearch() {
        let zcode = command("zcode", name: "Zed", path: "/Applications/Zed.app")
        let zeta = command("zeta", name: "Zeta", path: "/Applications/Zeta.app")
        assertParse("z proj", custom: [zcode, zeta], mode: nil)
        // 缩写消除歧义后恢复触发
        assertParse("zc proj", custom: [zcode, zeta], mode: .customApp(zcode), keyword: "proj")
    }

    func testCustomPrefixOverridesBuiltinWord() {
        // 用户显式配置的内置同名前缀 = 意图覆盖
        let warp = command("t", name: "Warp", path: "/Applications/Warp.app")
        assertParse("t proj", custom: [warp], mode: .customApp(warp), keyword: "proj")
    }

    // MARK: - 内置命令词兜底语义（绑定规范名后同族别名跟随）

    func testBuiltinTerminalFollowsUserBindingOfCanonicalName() {
        // terminal → Otty 后，t 与 terminal 都用 Otty（内置词只做兜底）
        let otty = command("terminal", name: "Otty", path: "/Applications/Otty.app")
        assertParse("t proj", custom: [otty], mode: .customApp(otty), keyword: "proj")
        assertParse("terminal proj", custom: [otty], mode: .customApp(otty), keyword: "proj")
    }

    func testBuiltinOpenFollowsUserBindingOfCanonicalName() {
        let visor = command("open", name: "Visor", path: "/Applications/Visor.app")
        assertParse("o note", custom: [visor], mode: .customApp(visor), keyword: "note")
        assertParse("open note", custom: [visor], mode: .customApp(visor), keyword: "note")
    }

    func testExactAliasBindingWinsOverUnboundFamilyMember() {
        // 显式绑定别名本身（t → Warp）优先；未绑定的 terminal 仍走内置 Terminal
        let warp = command("t", name: "Warp", path: "/Applications/Warp.app")
        assertParse("t proj", custom: [warp], mode: .customApp(warp), keyword: "proj")
        assertParse("terminal proj", custom: [warp], mode: .terminal, keyword: "proj")
    }

    func testBuiltinFallbackIntactWithoutRelatedBinding() {
        // 不相干的绑定（zcode）不影响内置词兜底
        let zcode = command("zcode", name: "Zed", path: "/Applications/Zed.app")
        assertParse("t proj", custom: [zcode], mode: .terminal, keyword: "proj")
        assertParse("o proj", custom: [zcode], mode: .finder, keyword: "proj")
    }

    func testBuiltinWordStillWorksWhenNoCustomConflict() {
        assertParse("t proj", custom: [command("zcode", name: "Zed", path: "/Applications/Zed.app")], mode: .terminal, keyword: "proj")
    }

    func testNoSpaceConcatenationIsNotACommand() {
        assertParse("zcodeproj", custom: [command("zcode", name: "Zed", path: "/Applications/Zed.app")], mode: nil)
    }

    func testInvalidCustomPrefixesNeverMatch() {
        // 空白前缀无法作为单词触发（Preferences 读取层也会过滤，解析器兜底）
        assertParse("proj", custom: [command("  ", name: "A", path: "/Applications/A.app")], mode: nil)
        assertParse("proj x", custom: [command("my app", name: "B", path: "/Applications/B.app")], mode: nil)
    }

    // MARK: - 锚定关键字透传

    func testKeywordWithAnchorsPassesThroughRaw() {
        let zcode = command("zcode", name: "Zed", path: "/Applications/Zed.app")
        assertParse("zcode /proj", custom: [zcode], mode: .customApp(zcode), keyword: "/proj")
        assertParse("t proj/", mode: .terminal, keyword: "proj/")
        assertParse("t /proj/", mode: .terminal, keyword: "/proj/")
    }
}
