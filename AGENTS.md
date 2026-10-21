# AGENTS.md

本文件供 AI 编码助手（以及新接手的开发者）在本仓库工作时参考。**改动前请先通读「性能设计」与「已踩坑记录」两节，避免回退已修复的问题。**

## 项目概述

OpenMyApp 是一个 macOS 极简应用启动器（SwiftUI + AppKit，**零第三方依赖**）。核心交互仿 Spotlight：启动即显示悬浮搜索框，输入拼音 / 英文名搜索本机应用程序与系统设置面板，回车打开第一项；点击面板外自动隐藏；菜单栏常驻且可隐藏图标；全局快捷键可在设置中自定义。

- 最低系统：macOS 15.0
- 语言模式：Swift 5（`SWIFT_VERSION: "5.0"`，非 Swift 6 严格并发）
- 常驻形态：`LSUIElement=true`（无 Dock 图标，托盘驻留）

## 常用命令

```bash
xcodegen generate          # 改了 Sources/Resources 文件结构后必须重新生成（*.xcodeproj 不入库）
xcodebuild -project OpenMyApp.xcodeproj -scheme OpenMyApp -configuration Debug -derivedDataPath build build
xcodebuild -project OpenMyApp.xcodeproj -scheme OpenMyApp -configuration Release -derivedDataPath build build
swift scripts/generate-icon.swift   # 重新生成应用图标（改 scripts/generate-icon.swift 后执行）
./scripts/bump-version.sh patch     # 升级版本号（同步 VERSION / package.json / project.yml）
./scripts/check-sensitive.sh        # 敏感信息扫描（push 前必跑）
```

运行应用做真实验证：

```bash
nohup build/Build/Products/Debug/OpenMyApp.app/Contents/MacOS/OpenMyApp > /tmp/openmyapp_run.log 2>&1 & disown
# 日志走 NSLog（stderr），运行日志在 /tmp/openmyapp_run.log；索引用 NSLog("[OpenMyApp] 应用索引已刷新: N 个应用")
```

## 源码结构（Sources/）

| 目录 | 职责 | 关键类型 |
|------|------|----------|
| `App/` | 入口、生命周期、悬浮面板窗口、托盘 | `AppDelegate`, `PanelController`, `StatusBarController`, `main.swift` |
| `Search/` | 数据源与检索 | `AppIndexer`（扫 /Applications 等 + 中文名提取）、`AppDirectoryWatcher`（FSEvents 目录监听）、`SystemSettingsCatalog`（设置面板锚点）、`Pinyin`（CFStringTransform 转拼音）、`SearchEngine`（打分排序）、`SearchResult` |
| `UI/` | 界面 | `LauncherView` / `LauncherModel`（搜索框 + 结果列表）、`SettingsWindow`（含快捷键录制 `HotkeyRecorderButton`）、`VisualEffectBackground` |
| `Hotkey/` | 全局快捷键 | `HotkeyManager`（Carbon RegisterEventHotKey，无需辅助功能权限）、`HotkeyDisplay`（keyCode+掩码 ↔ "⌥Space" 展示互转） |
| `Utils/` | 偏好与使用频次 | `Preferences`（UserDefaults 封装，使用频次带内存缓存） |

## 关键设计

- 悬浮面板是**无边框** `NSPanel`（`.borderless + .nonactivatingPanel`，圆角由内容层 `VisualEffectBackground` 自绘）。无边框窗口默认不可成为 key window，靠 `LauncherPanel.canBecomeKey` 重写解决；**不能用 `.titled + .fullSizeContentView` 冒充无边框**——即使隐藏标题文字，标题栏安全区高度仍在，面板顶部会留一条空白（实测踩过）。`NSHostingController.sizingOptions = [.preferredContentSize]` 让窗口随结果数量伸缩，`windowDidResize` 保持顶边不动；构建面板时必须先 `setContentSize` 给初始尺寸，否则 SwiftUI 布局完成前宽度为 0，居中定位会算错（实测踩过）。
- 点击面板外隐藏 = 全局鼠标监听（其他应用）+ 本地鼠标监听（本应用其他窗口）双通道；监听**仅在面板可见时安装**，隐藏即卸载（见性能设计）。
- 系统设置面板通过 `x-apple.systempreferences:<扩展锚点>` 打开（macOS 13+），锚点清单在 `SystemSettingsCatalog`。
- 中文搜索：应用名经 `kCFStringTransformMandarinLatin` + 去声调得到全拼与首字母，配合原名 / 英文名打分（前缀 > 包含 > 子序列），再叠加使用频次加权。系统语言非中文时，第三方应用读 bundle 内 `zh_CN.lproj/InfoPlist.strings` 强制取中文名；**系统应用资源在 dyld 共享缓存中读不到**，用 `AppIndexer.zhNameOverrides` 静态对照表兜底（新增系统应用支持不了拼音时，先查这张表）。
- 索引新鲜度双通道：面板每次显示时后台重扫（`LauncherModel.prepare()`，60s 保鲜期内跳过），`AppDirectoryWatcher` 用 FSEvents 监听应用目录（只监听启动时已存在的目录），去抖 1.5s 后 `force` 重扫——面板隐藏时索引也会更新。
- 全局快捷键可在设置页自定义：偏好存 keyCode + Carbon 修饰键掩码（`Preferences.hotkeyKeyCode/hotkeyCarbonMask`），`HotkeyRecorderButton` 录制（要求 ⌘/⌥/⌃ 至少一个），变更经 `SettingsWindowController.onPreferenceChanged` 触发 `HotkeyManager.reRegister()` 与托盘刷新。

## 性能设计（勿回退）

- **内存**：索引不持有 NSImage——图标在结果行渲染时经 `NSWorkspace.icon(forFile:)` 按需解析（系统内部缓存），只有可见的 ≤9 行产生图标对象。物理占用 ~29MB（`ps` 里的 RSS ~103MB 是共享框架映射页，不是真实增量，评估占用用 `vmmap --summary | grep "Physical footprint"`）。
- **搜索热路径**（基线 94µs/次，Swift -O，~190 应用 + 36 设置项）：
  - 查询级预计算 `queryBytes` / `asciiQuery`，每次搜索只算一次（曾因放在 `isSubsequence` 内逐字符判定成为热点）
  - 包含匹配用 `SearchEngine.bytesContain`（手写首字节剪枝，零分配）。**禁用** `String.contains`（走 Foundation locale 感知搜索）和 `utf8.firstRange(of:)`（每次调用 `_copyToContiguousArray` 拷贝两串建 ZSearcher）——采样实测两者都慢一个量级以上
  - 子序列匹配：ASCII 查询走 UTF-8 字节 `formIndex` 手写扫描；非 ASCII 退回 Character 级（避免跨字符边界假匹配）
  - 使用频次缓存在 `Preferences` 静态内存（`UserDefaults.dictionary(forKey:)` 每次调用重新反序列化 plist，曾是打分热路径最大热点）
- **扫描**：`rescanApps(force:)` 带 60s 保鲜期，唤出面板时期内直接跳过；FSEvents 回调走 `force: true`；扫描在 `utility` 优先级后台
- **空闲功耗**：鼠标/键盘事件监听仅在面板可见时安装（`activateMonitors`），隐藏即卸载（`deactivateMonitors`；在监听回调内移除监听不安全，需 `DispatchQueue.main.async` 延迟一跳）。空闲时进程零定时器、零轮询、零事件源，仅剩零开销的 Carbon 热键与 FSEvents，实测空闲 CPU 0.0%

## 编码规则

- UI 相关类型（AppDelegate / PanelController / LauncherModel / SearchEngine 等）标注 `@MainActor`；跨线程用 `Task { @MainActor in }` 包裹。后台纯计算（如目录扫描）用 `Task.detached`。
- `main.swift` 顶层不能直接调用 `@MainActor` 构造器，用 `MainActor.assumeIsolated { AppDelegate() }`（Swift 5 语言模式下的标准写法）。
- 项目零第三方依赖，新增功能优先用系统框架；引入依赖属于方案级变更，需先说明理由。
- 面向用户的字符串用中文；代码注释只写代码本身说不清的约束（为什么不用某个 API、为什么必须有某步），不写"这行做了什么"。
- 用户偏好一律走 `Preferences`（UserDefaults），不要散落直接读 `UserDefaults.standard`。

## 测试与验证规则

- **构建门禁**：任何改动后 `xcodebuild` Debug 构建必须通过才算完成；涉及发布面（脚本/CI/版本号）的改动再跑 Release。
- **真实环境复验**：UI/交互改动必须真实启动应用复验（截图确认面板渲染），不能只靠编译通过；验证完记得 `pkill -x OpenMyApp`。
- **搜索逻辑离线验证**：把 `Sources/Search/*.swift + Sources/Utils/Preferences.swift + Sources/Hotkey/HotkeyDisplay.swift` 与一个 `main.swift` 用 `swiftc -O` 编成命令行工具，跑典型查询断言排序（fangda→访达、fd→访达首位、shengyin→声音、vscode 子序列），并做耗时基准（当前基线 ~94µs/次，明显劣化要查）。
- **性能回归**：改动搜索/扫描路径时重复上述基准；内存评估用 `vmmap --summary` 的 Physical footprint，不要看 RSS。

## Git 与发布流程

- **git 身份必须是 GitHub noreply 邮箱**（本仓库已配置 `431787+steven0lisa@users.noreply.github.com`），禁止公司邮箱；提交后自检：`git log -1 --format='%an <%ae>'`。
- 版本号唯一来源是 `VERSION`，由 `scripts/bump-version.sh patch|minor|major` 同步到 `package.json` 与 `project.yml`；发版日志写在 `package.json` 的 `releaseHistory`。
- 发版：bump → 提交 → `git tag vx.y.z` → 推送，GitHub Actions 自动构建 DMG 并发 Release（构建前有敏感扫描兜底）。
- 提交只 add 本会话明确改动的文件，`git add -A` 前先 `git status` 甄别（并行会话可能留下无关 WIP）。
- **提交信息用英文**（Conventional Commits 风格：`feat:` / `fix:` / `perf:` / `docs:` / `chore:`）。
- **README 双语维护**：`README.md` 英文（GitHub 默认展示）+ `README.zh-CN.md` 中文，内容变更需同步两个文件及顶部语言切换链接。
- **发版日志用英文**：`package.json` 的 `releaseHistory`（CI 会作为 GitHub Release Notes 自动生成）全部写英文；新增条目时注意核对 version 字段（bump-version.sh 的 sed 会把旧条目的 version 一并替换）。

## 敏感信息规则（强制）

- **推送 GitHub 前必须跑 `./scripts/check-sensitive.sh`**：FAIL 项（凭据 / 公司名 / 内网域名 / webhook / 带密码连接串）必须删除或替换为占位符；WARN 项（邮箱 / 本机绝对路径 / 真实姓名 / 手机号）人工确认。
- CI（release.yml）在构建前会再跑一次同样的扫描作为兜底。
- `.v2c/`、`.findings/`、`build/`、`dist/`、`*.xcodeproj/` 等本地目录已入 `.gitignore`，不要无过目直接提交。

## 已踩坑记录（改相关代码前先看）

1. **Finder（访达）不在 `/System/Applications`**，在 `/System/Library/CoreServices/Finder.app`——`AppIndexer.scan()` 末尾有显式路径，别删。
2. **系统应用中文名读不到**：磁盘上有 zh_CN.lproj 但 InfoPlist.strings 在 dyld 共享缓存里，`Bundle.path(forResource:forLocalization:)` 返回 nil——只能靠 `zhNameOverrides` 静态表。
3. **Swift 字符串搜索两大陷阱**：`String.contains` 走 Foundation locale 感知搜索；`utf8.firstRange(of:)` 每次调用拷贝数组建 ZSearcher。搜索热路径一律用 `bytesContain` / 字节级 `isSubsequence`。做基准时注意 `||` 短路会让微基准几乎不执行（踩过）。
4. **本机 bash 3.2 + `set -u`：中文全角括号紧贴 `$var` 会被解析成未绑定变量**（`check-sensitive.sh` 踩过）——shell 脚本里全角标点与 `$var` 不要相邻。
5. **NSPanel 没有 `becomesKeyOnlyFirstResponder` 属性**（头文件只有 `becomesKeyOnlyIfNeeded`）。**borderless 面板默认不可成为 key window**，必须子类化重写 `canBecomeKey → true`（`LauncherPanel`），titled 面板则无此问题——但 titled + fullSizeContentView 有标题栏安全区空隙问题，见「关键设计」。`NSTextView.hasMarkedText()` 是**方法**不是属性（输入法组字判断）。
6. **后台进程验证会被工具调用结束杀掉**：长驻验证用 `nohup … & disown` 脱离；GUI 自动化按键（osascript System Events）需先把应用 `set frontmost`，但其他应用抢焦点会导致按键落错目标——交互链路测试尽量在单次脚本内原子完成。
7. **结果列表高度公式**：`PanelMetrics.listHeight` 必须等于 LazyVStack 实际内容高度（`count×46 + (count-1)×4 + 20` 上下 padding），算少 10pt 就会出现滚动条（实测踩过）。
