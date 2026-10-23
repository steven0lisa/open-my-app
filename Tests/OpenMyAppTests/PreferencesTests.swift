import XCTest

/// 自定义目录命令的偏好存取：JSON 序列化 roundtrip 与无效前缀过滤。
/// 直接操作 UserDefaults.standard，测试前后保存/恢复原值避免污染真实配置
final class PreferencesTests: XCTestCase {
    private static let key = "customAppCommands"
    private var original: Data?

    override func setUp() {
        super.setUp()
        original = UserDefaults.standard.data(forKey: Self.key)
    }

    override func tearDown() {
        if let original {
            UserDefaults.standard.set(original, forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
        // 清掉内存缓存，后续读取回落到 defaults 真实值
        Preferences.customAppCommands = []
        super.tearDown()
    }

    private func command(
        _ prefix: String,
        name: String = "App",
        path: String = "/Applications/App.app"
    ) -> CustomAppCommand {
        CustomAppCommand(id: UUID(), prefix: prefix, appName: name, appPath: path)
    }

    func testRoundtrip() {
        let zcode = command("zcode", name: "Zed", path: "/Applications/Zed.app")
        Preferences.customAppCommands = [zcode]
        XCTAssertEqual(Preferences.customAppCommands, [zcode])

        Preferences.customAppCommands = []
        XCTAssertTrue(Preferences.customAppCommands.isEmpty)
    }

    func testEmptyAndWhitespacePrefixesFilteredOnWrite() {
        let valid = command("zcode", name: "Zed", path: "/Applications/Zed.app")
        let blank = command("   ", name: "Blank", path: "/Applications/Blank.app")
        let spaced = command("my app", name: "Spaced", path: "/Applications/Spaced.app")
        Preferences.customAppCommands = [blank, valid, spaced]
        // 含空白的前缀永远无法作为单词触发，写入侧即剔除，保证内存缓存与冷启动读取一致
        XCTAssertEqual(Preferences.customAppCommands, [valid])
    }
}
