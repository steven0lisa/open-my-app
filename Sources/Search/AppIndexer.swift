import AppKit

struct IndexedApp {
    let path: String
    /// 本地化展示名（随系统语言；用户系统为英文时是英文名）
    let name: String
    /// 强制读取的简体中文名（来自 bundle 的 zh_CN.lproj），可能为 nil
    let chineseName: String?
    /// bundle 文件名（去 .app 后缀），如 "Finder"
    let englishName: String
    let icon: NSImage
}

/// 扫描常见目录下的 .app 应用
enum AppIndexer {
    static var searchDirectories: [String] {
        [
            "/Applications",
            "/System/Applications",
            "/Applications/Utilities",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
    }

    /// 系统应用的中文名对照（系统应用资源在 dyld 共享缓存中，磁盘上无法读取 zh lproj 的
    /// InfoPlist.strings；第三方应用走 bundle 提取，不在此表）
    static let zhNameOverrides: [String: String] = [
        "Finder": "访达",
        "Find My": "查找",
        "Activity Monitor": "活动监视器",
        "AirPort Utility": "机场实用工具",
        "Archive Utility": "归档实用工具",
        "Audio MIDI Setup": "音频 MIDI 设置",
        "Automator": "自动操作",
        "Books": "图书",
        "Boot Camp Assistant": "启动转换助理",
        "Calculator": "计算器",
        "Calendar": "日历",
        "Certificate Assistant": "证书助理",
        "Chess": "棋",
        "ColorSync Utility": "ColorSync 实用工具",
        "Console": "控制台",
        "Contacts": "通讯录",
        "Digital Color Meter": "数码测色计",
        "Disk Utility": "磁盘工具",
        "Dictionary": "词典",
        "FaceTime": "FaceTime 通话",
        "Font Book": "字体册",
        "Freeform": "无边记",
        "Grapher": "绘图计算器",
        "Home": "家庭",
        "Image Capture": "图像捕捉",
        "Journal": "手记",
        "Keychain Access": "钥匙串访问",
        "Launchpad": "启动台",
        "Mail": "邮件",
        "Maps": "地图",
        "Messages": "信息",
        "Migration Assistant": "迁移助理",
        "Mission Control": "调度中心",
        "Music": "音乐",
        "News": "新闻",
        "Notes": "备忘录",
        "Password": "密码",
        "Photo Booth": "照片亭",
        "Photos": "照片",
        "Podcasts": "播客",
        "Preview": "预览",
        "QuickTime Player": "QuickTime 播放器",
        "Reminders": "提醒事项",
        "Screen Sharing": "屏幕共享",
        "Screenshot": "截图",
        "Script Editor": "脚本编辑器",
        "Shortcuts": "快捷指令",
        "Stickies": "便签",
        "Stocks": "股市",
        "Storage Management": "储存空间管理",
        "System Information": "系统信息",
        "Terminal": "终端",
        "TextEdit": "文本编辑",
        "Time Machine": "时间机器",
        "TV": "TV",
        "Voice Memos": "语音备忘录",
        "Weather": "天气",
        "Wireless Diagnostics": "无线诊断",
    ]

    static func scan() -> [IndexedApp] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var apps: [IndexedApp] = []

        func appendApp(at path: String) {
            guard fileManager.fileExists(atPath: path), !seen.contains(path) else { return }
            seen.insert(path)
            // displayName 在部分环境下会带回 ".app" 后缀，统一去掉
            var name = fileManager.displayName(atPath: path)
            if name.lowercased().hasSuffix(".app") {
                name = String(name.dropLast(4))
            }
            apps.append(
                IndexedApp(
                    path: path,
                    name: name,
                    chineseName: zhDisplayName(bundlePath: path) ?? zhNameOverrides[((path as NSString).lastPathComponent as NSString).deletingPathExtension],
                    englishName: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                    icon: NSWorkspace.shared.icon(forFile: path)
                )
            )
        }

        for directory in searchDirectories {
            guard let items = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for item in items.sorted() where item.hasSuffix(".app") {
                appendApp(at: (directory as NSString).appendingPathComponent(item))
            }
        }
        // 访达（Finder.app）不在 /System/Applications，而在 CoreServices
        appendApp(at: "/System/Library/CoreServices/Finder.app")
        return apps
    }

    /// 强制读取简体中文名：用户系统语言不是中文时也能支持拼音搜索
    private static func zhDisplayName(bundlePath: String) -> String? {
        guard let bundle = Bundle(path: bundlePath) else { return nil }
        for localization in ["zh-Hans", "zh_CN", "zh-Hans-CN"] {
            guard let stringsPath = bundle.path(
                forResource: "InfoPlist",
                ofType: "strings",
                inDirectory: nil,
                forLocalization: localization
            ), let dict = NSDictionary(contentsOfFile: stringsPath) as? [String: Any] else {
                continue
            }
            let name = (dict["CFBundleDisplayName"] ?? dict["CFBundleName"]) as? String
            if let name, !name.isEmpty {
                return name
            }
        }
        return nil
    }
}
