# AGENTS.md

本文件供 AI 编码助手（以及新接手的开发者）在本仓库工作时参考。**改动前请先通读「性能设计」与「已踩坑记录」两节，避免回退已修复的问题。**

## 项目概述

OpenMyApp 是一个 macOS 极简应用启动器（SwiftUI + AppKit，**零第三方依赖**）。核心交互仿 Spotlight：启动即显示悬浮搜索框，输入拼音 / 英文名搜索本机应用程序与系统设置面板，回车打开第一项；空查询时以 Launchpad 式图标网格铺开全部应用（按最常用排序，方向键可在网格中移动）；点击面板外自动隐藏；菜单栏常驻且可隐藏图标；全局快捷键可在设置中自定义。

- 最低系统：macOS 15.0
- 语言模式：Swift 5（`SWIFT_VERSION: "5.0"`，非 Swift 6 严格并发）
- 常驻形态：`LSUIElement=true`（无 Dock 图标，托盘驻留）

## 常用命令

```bash
xcodegen generate          # 改了 Sources/Resources/Tests 文件结构后必须重新生成（*.xcodeproj 不入库）
xcodebuild -project OpenMyApp.xcodeproj -scheme OpenMyApp -configuration Debug -derivedDataPath build build
xcodebuild -project OpenMyApp.xcodeproj -scheme OpenMyApp -configuration Release -derivedDataPath build build
./scripts/run-tests.sh              # 单元测试（推送前必跑，pre-push 钩子自动执行）
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
| `Update/` | 检查更新与自动安装 | `UpdateChecker`（GitHub Release 查询、DMG 下载、挂载安装、重启） |
| `Clipboard/` | 剪切板历史 | `ClipboardManager`（粘贴板轮询/捕获/缩略图/回写+自动粘贴）、`ClipboardStore`（SQLite + FTS5 全文索引）、`ClipboardItem`（记录模型） |
| `Search/` 补充 | 文件命令搜索 | `FileSearchService`（NSMetadataQuery 封装，t/o 命令） |
| `Utils/` | 偏好与使用频次 | `Preferences`（UserDefaults 封装，使用频次带内存缓存） |
| `../Tests/OpenMyAppTests/` | 单元测试（logic bundle，清单见 project.yml） | `CommandRouterTests` / `FileSearchServiceTests` / `LauncherModelPathTests` / `PreferencesTests` |

## 关键设计

- 悬浮面板是**无边框** `NSPanel`（`.borderless + .nonactivatingPanel`，圆角由内容层 `VisualEffectBackground` 自绘）。无边框窗口默认不可成为 key window，靠 `LauncherPanel.canBecomeKey` 重写解决；**不能用 `.titled + .fullSizeContentView` 冒充无边框**——即使隐藏标题文字，标题栏安全区高度仍在，面板顶部会留一条空白（实测踩过）。`NSHostingController.sizingOptions = [.preferredContentSize]` 让窗口随结果数量伸缩，`windowDidResize` 保持顶边不动；构建面板时必须先 `setContentSize` 给初始尺寸，否则 SwiftUI 布局完成前宽度为 0，居中定位会算错（实测踩过）。
- 点击面板外隐藏 = 全局鼠标监听（其他应用）+ 本地鼠标监听（本应用其他窗口）双通道；监听**仅在面板可见时安装**，隐藏即卸载（见性能设计）。
- 系统设置面板通过 `x-apple.systempreferences:<扩展锚点>` 打开（macOS 13+），锚点清单在 `SystemSettingsCatalog`。
- 中文搜索：应用名经 `kCFStringTransformMandarinLatin` + 去声调得到全拼与首字母，配合原名 / 英文名打分（前缀 > 包含 > 子序列），再叠加使用频次加权。系统语言非中文时，第三方应用读 bundle 内 `zh_CN.lproj/InfoPlist.strings` 强制取中文名；**系统应用资源在 dyld 共享缓存中读不到**，用 `AppIndexer.zhNameOverrides` 静态对照表兜底（新增系统应用支持不了拼音时，先查这张表）。
- 索引新鲜度双通道：面板每次显示时后台重扫（`LauncherModel.prepare()`，60s 保鲜期内跳过），`AppDirectoryWatcher` 用 FSEvents 监听应用目录（只监听启动时已存在的目录），去抖 1.5s 后 `force` 重扫——面板隐藏时索引也会更新。
- `t` / `terminal` + 空格 + 关键字、`o` / `open` + 空格 + 关键字命令，以及**自定义前缀命令**（设置页「Custom Folder Commands」配置 前缀 → 应用，如 `zcode` → iTerm）：Spotlight 元数据搜索 HOME 下的目录 / 文件，回车分别用 Terminal 打开目录、Finder 打开（文件则定位选中）、绑定应用打开目录（`NSWorkspace.open(_:withApplicationAt:)`）。解析统一在 `CommandRouter`：完全匹配优先（自定义前缀可覆盖内置词），自定义前缀支持唯一缩写（`z` → `zcode`；缩写歧义或裸缩写不带关键字时不进命令态，仍走普通 app 搜索；内置词仅完整匹配）。结果排序按「完整匹配 > 前缀匹配 > 包含匹配」，由分阶段 Spotlight 查询保证（见踩坑 9）；关键字支持 `/` 锚定：前导 `/` = 名以其开头、尾随 `/` = 名以其结尾（`t /google`、`t google/`）。命令结果行 `ResultKind.customApp(path:name:)` 的图标与右侧标签按绑定应用解析。实现要点（实测踩过，勿回退）：结果主要经 `NSMetadataQueryGatheringProgress` 通知携带，`NSMetadataQueryDidUpdate` 只在 gathering 完成后索引变化时触发（且真名带 "Did"，手写 raw string 永远不触发）；`kMDItemPath` 在谓词中不受支持（静默忽略），Library 排除只能在 collect 内存侧做；没有结果数上限 API，limit 靠 collect 截断 + 攒满即 stop；输入侧 250ms 防抖，代次计数丢弃过期回调；范围限定 HOME 规避 TCC 弹窗；常见依赖库 / 构建目录（node_modules、target、DerivedData 等，清单见 `FileSearchService.excludedDirectoryNames`）在 collect 内存侧按路径组件排除；行标题按本批结果公共目录前缀省略为 `…/`（`LauncherModel.elidedPaths`，路径头部雷同时尾部才是区分点），完整路径放悬浮提示。自定义命令存 `Preferences.customAppCommands`（JSON in UserDefaults + 内存缓存，读取时过滤空前缀 / 含空白前缀）。
- 界面双语（en / zh-CN）：开发区域为 en，key 即英文文案，`Resources/zh-CN.lproj/Localizable.strings` 存中文对照；新增 UI 字符串必须走 `NSLocalizedString` 并补中文条目。应用的搜索数据（中文名对照）与 UI 语言无关，始终强制取中文名做拼音匹配。
- 设置窗口按 Tab 拆分（General / Hotkeys / Folder Commands / Clipboard / About），切换条用 segmented `Picker` 自绘、窗口高度随 Tab 内容变化（`NSHostingController.sizingOptions = [.preferredContentSize]`，各 Tab 高度在 `SettingsView.contentHeight` 按内容量给定，新增 Tab 或行时同步调整）。**不要用 SwiftUI `TabView`**：macOS 上默认样式与标题栏之间有空带、tab 条四周留白怪异，实测观感很差（2026-10-22 用户点名退回）。
- 检查更新双通道：api.github.com 优先（tag + asset 直链），403 / 共享出口 IP 限流时回退到 `github.com/.../releases/latest` 的 302 重定向提取 tag、按 `releases/download/<tag>/OpenMyApp-<ver>.dmg` 命名规律推导直链；安装 = hdiutil 挂载到临时目录 → 替换 /Applications → `open -n` 延迟重启。
- 全局快捷键可在设置页自定义：偏好存 keyCode + Carbon 修饰键掩码（`Preferences.hotkeyKeyCode/hotkeyCarbonMask`），`HotkeyRecorderButton` 录制（要求 ⌘/⌥/⌃ 至少一个），变更经 `SettingsWindowController.onPreferenceChanged` 触发 `HotkeyManager.reRegister()` 与托盘刷新。**双热键**：主热键（普通面板）+ 剪切板热键（默认 ⌘⇧V，`Preferences.clipboardHotkey*`），`HotkeyManager` 按 EventHotKeyID id 区分回调 `.main` / `.clipboard`。
- 登录自启动**默认开启**：首次启动做一次性 SMAppService 注册引导（`Preferences.launchAtLoginAutoConfigured` 防重复），之后一切以设置页开关为准——用户关掉的自启动不能被后续启动悄悄打开。注意 debug 构建与生产构建共享 bundle 偏好（非沙箱按 bundleId 存储），debug 跑过引导会置位标记。
- 剪切板历史：`ClipboardManager` 在 workQueue 上 1s 轮询 `NSPasteboard.changeCount`（系统无变更通知，只能轮询；只读计数不读内容），变更后按 文件引用（Finder 复制，只存路径）> 图片（统一转 PNG）> 文本 的优先级捕获；>16KB 文本与图片落盘 `App Support/OpenMyApp/clipboard-files/`，DB 只存引用 + preview，去重靠 SHA256(content_hash)（同内容置顶、use_count 保留）。搜索 = 内存缓存（最近 200 条 + 预计算小写检索文本，主线程同步 0.16ms/次，见性能设计）+ SQLite 异步补齐（代次计数丢弃过期回调）：全部词元 ≥3 **字符**走 FTS5 trigram 索引（覆盖大文本全文，任意子串、ASCII 大小写折叠），否则 LIKE 兜底扫 preview/content/file_path；搜索词按空格分词 AND 匹配。普通模式 app 与剪切板各最多展示 3 条；**普通模式空查询 = 全量应用网格**（Launchpad 风，7 列最多露出 4 行可滚动，按最常用排序，2026-10-23 用户新增需求）——但**剪切板内容依然绝不进普通模式空查询**（唤出即闪出最近剪贴内容扰人且有泄露风险，v1.3.1 修的问题对剪切板内容仍成立）；**浏览态标志（`LauncherModel.isBrowsingApps`）必须在 `refresh()` 顶部先于命令路由判定**，命令结果（t/o/自定义）永远以列表渲染——先路由命令后复位标志会把命令结果渲染成网格（v1.4.0 实撞、v1.4.1 修）；剪切板模式（`SearchMode.clipboard`）只搜剪切板，空查询展示最近 9 条。回车 = 回写剪切板 + CGEvent 模拟 ⌘V 自动粘贴（需辅助功能权限，未授权降级仅复制并引导授权一次）；文件记录回写的是**路径文本**（产品决策）。自己的回写经 `suppressedChangeCount` 防轮询再捕获。每日清理：删「创建超过保留天数（`Preferences.clipboardRetentionDays`，默认 21）且使用次数 < 阈值（`clipboardKeepUsageCount`，默认 2）」的记录（含落盘文件与 FTS 行），参数在设置页剪切板 Tab 配置，变更经 `ClipboardManager.cleanNow()` 立即生效；持续运行下熬过保留期的记录必然用过 ≥阈值、永久保留。面板每次显示都清空搜索框并按模式重置（`LauncherModel.prepare(mode:)`）。

## 性能设计（勿回退）

- **内存**：索引不持有 NSImage——图标在结果行/网格格渲染时经 `NSWorkspace.icon(forFile:)` 按需解析（系统内部缓存），只有可见的行（列表 ≤9 行、网格 ≤28 格）产生图标对象。物理占用 ~29MB（`ps` 里的 RSS ~103MB 是共享框架映射页，不是真实增量，评估占用用 `vmmap --summary | grep "Physical footprint"`）。
- **搜索热路径**（基线 94µs/次，Swift -O，~190 应用 + 36 设置项）：
  - 查询级预计算 `queryBytes` / `asciiQuery`，每次搜索只算一次（曾因放在 `isSubsequence` 内逐字符判定成为热点）
  - 包含匹配用 `SearchEngine.bytesContain`（手写首字节剪枝，零分配）。**禁用** `String.contains`（走 Foundation locale 感知搜索）和 `utf8.firstRange(of:)`（每次调用 `_copyToContiguousArray` 拷贝两串建 ZSearcher）——采样实测两者都慢一个量级以上
  - 子序列匹配：ASCII 查询走 UTF-8 字节 `formIndex` 手写扫描；非 ASCII 退回 Character 级（避免跨字符边界假匹配）
  - 使用频次缓存在 `Preferences` 静态内存（`UserDefaults.dictionary(forKey:)` 每次调用重新反序列化 plist，曾是打分热路径最大热点）
- **扫描**：`rescanApps(force:)` 带 60s 保鲜期，唤出面板时期内直接跳过；FSEvents 回调走 `force: true`；扫描在 `utility` 优先级后台
- **空闲功耗**：鼠标/键盘事件监听仅在面板可见时安装（`activateMonitors`），隐藏即卸载（`deactivateMonitors`；在监听回调内移除监听不安全，需 `DispatchQueue.main.async` 延迟一跳）。空闲时进程零定时器、零轮询、零事件源，仅剩零开销的 Carbon 热键与 FSEvents，实测空闲 CPU 0.0%
- **剪切板搜索热路径**（2026-10-22 真实 2237 条数据基准，勿回退）：
  - **内存缓存条目必须携带预计算的小写检索文本**（`ClipboardManager.MemoryEntry`，装载/新捕获时算一次）——若在搜索循环里对每条现算 `searchTextLower`（computed 属性每次 lowercased() 全文），200 条 × ≤16KB 内容 = 每次按键 ~1.9ms 主线程耗时 + MB 级临时字符串分配；预计算后 0.16ms（12 倍）
  - DB 侧无需再优化：FTS 路径 0.1~0.22ms/次，LIKE 兜底 0.03~0.11ms/次，浏览查询 0.02ms/次（DB 8.2MB / content 总量 646KB 规模下）
  - **缩略图双阈值**：字节数 >512KB **或** 像素尺寸 >880px 都生成缩略图——高分辨率截图 PNG 压缩率高（几十 KB 但上万像素），只按字节数判断会在行渲染时整图解码、几十 MB 解码内存一闪而过；缩略图 NSCache countLimit=16（可见 9 行 + 余量）

## 编码规则

- UI 相关类型（AppDelegate / PanelController / LauncherModel / SearchEngine 等）标注 `@MainActor`；跨线程用 `Task { @MainActor in }` 包裹。后台纯计算（如目录扫描）用 `Task.detached`。
- `main.swift` 顶层不能直接调用 `@MainActor` 构造器，用 `MainActor.assumeIsolated { AppDelegate() }`（Swift 5 语言模式下的标准写法）。
- 项目零第三方依赖，新增功能优先用系统框架；引入依赖属于方案级变更，需先说明理由。
- 面向用户的字符串用中文；代码注释只写代码本身说不清的约束（为什么不用某个 API、为什么必须有某步），不写"这行做了什么"。
- 用户偏好一律走 `Preferences`（UserDefaults），不要散落直接读 `UserDefaults.standard`。

## 测试与验证规则

- **单元测试（推送前强制）**：`Tests/OpenMyAppTests/`，覆盖命令解析（`CommandRouterTests`）、`/` 锚定解析与谓词映射（`FileSearchServiceTests`）、路径展示工具（`LauncherModelPathTests`）、自定义命令偏好存取（`PreferencesTests`）。统一入口 `./scripts/run-tests.sh`；**pre-push 钩子自动执行**（本仓库已配 `core.hooksPath .githooks`，新克隆必须执行 `git config core.hooksPath .githooks` 安装）；CI 发版构建前也会再跑一轮。测试 target 是 logic bundle（不启动 App）：被测源文件直接编进测试 bundle，清单在 project.yml 的 `OpenMyAppTests.sources`——**新增被测源文件时必须同步该清单**。跑测试会写 `Preferences`（UserDefaults），测试类须自行保存/恢复原值。
- **构建门禁**：任何改动后 `xcodebuild` Debug 构建必须通过才算完成；涉及发布面（脚本/CI/版本号）的改动再跑 Release。
- **真实环境复验**：UI/交互改动必须真实启动应用复验（截图确认面板渲染），不能只靠编译通过；验证完记得 `pkill -x OpenMyApp`。
- **搜索逻辑离线验证**：把 `Sources/Search/*.swift + Sources/Utils/Preferences.swift + Sources/Hotkey/HotkeyDisplay.swift` 与一个 `main.swift` 用 `swiftc -O` 编成命令行工具，跑典型查询断言排序（fangda→访达、fd→访达首位、shengyin→声音、vscode 子序列），并做耗时基准（当前基线 ~94µs/次，明显劣化要查）。
- **性能回归**：改动搜索/扫描路径时重复上述基准；内存评估用 `vmmap --summary` 的 Physical footprint，不要看 RSS。

## Git 与发布流程

> 本仓库的发版流水线方案沉淀在 general-staff：**GS-SOL-004 v1.0**（`data/solutions/macos-github-release-pipeline/`，含 4 个通用模板与踩坑清单；脚本演进后须回写该模板并递增其版本号）。

- **git 身份必须是 GitHub noreply 邮箱**（本仓库已配置 `431787+steven0lisa@users.noreply.github.com`），禁止公司邮箱；提交后自检：`git log -1 --format='%an <%ae>'`。
- 版本号唯一来源是 `VERSION`，由 `scripts/bump-version.sh patch|minor|major` 同步到 `package.json` 与 `project.yml`；发版日志写在 `package.json` 的 `releaseHistory`。
- 发版：bump → 提交 → `git tag vx.y.z` → 推送，GitHub Actions 自动构建 DMG 并发 Release（构建前有敏感扫描兜底）。
- 提交只 add 本会话明确改动的文件，`git add -A` 前先 `git status` 甄别（并行会话可能留下无关 WIP）。
- **提交信息用英文**（Conventional Commits 风格：`feat:` / `fix:` / `perf:` / `docs:` / `chore:`）。
- **README 双语维护**：`README.md` 英文（GitHub 默认展示）+ `README.zh-CN.md` 中文，内容变更需同步两个文件及顶部语言切换链接。
- **发版日志用英文**：`package.json` 的 `releaseHistory`（CI 会作为 GitHub Release Notes 自动生成）全部写英文；新增条目时注意核对 version 字段（bump-version.sh 的 sed 会把旧条目的 version 一并替换）。

## 敏感信息规则（强制）

- **推送 GitHub 前必须跑 `./scripts/check-sensitive.sh`**：FAIL 项（凭据 / 公司名 / 内网域名 / webhook / 带密码连接串）必须删除或替换为占位符；WARN 项（邮箱 / 本机绝对路径 / 真实姓名 / 手机号）人工确认。
- **公司/雇主专属敏感词不得硬编码在本仓库任何文件里**（公开仓库暴露雇主信息，check-sensitive.sh 自身的泄密就是这么发生的——它曾把自己排除在扫描外）。清单外置在仓库外：`~/.zcode/secrets/sensitive-local-patterns.txt`（本机全局，跨项目共用；一行一个 ERE，# 为注释），脚本自动加载按 FAIL 级别扫描；备选位置 `scripts/sensitive-local.txt`（已 gitignore）。清单只在本地存在、CI 拿不到——公司名泄露的防线是本地推送前扫描。
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
8. **FTS5 trigram 分词 ≥3 字符才成块**：判断查询走 FTS 索引还是 LIKE 兜底，要按**字符数**（`$0.count >= 3`）而不是 UTF-8 字节数——中文 2 字 = 6 字节，按字节判定会误入 trigram 路径，而 2 字短语凑不出 trigram、永远匹配不上（离线测试踩过）。macOS 系统 SQLite（3.45+）自带 FTS5，`import SQLite3` 即用无需 linking 配置；FTS5 表用普通表（非 contentless），删行直接 `DELETE FROM clip_fts WHERE rowid=?`。
9. **Spotlight 对 CONTAINS / BEGINSWITH 的返回顺序不可控**（2026-10-22 实测踩过）：`t work` 这类查询，名字完全等于关键字的目录可能排在几百条包含匹配之后，"候选池截断 + 内存排序"会把完整匹配整个挤出结果——排序保证只能靠**分阶段查询**下推给 Spotlight（`==` → `BEGINSWITH` → `CONTAINS` 依次补额度，见 `FileSearchService.search`），不能单条 CONTAINS 查完再排。另注意：目录可能根本不在 Spotlight 索引里（`mdls` 属性全 null，如本机 `~/work`），此时任何谓词都搜不到，属环境问题不是代码回归——排查时先 `mdls <目录>` 看索引状态。
10. **SwiftUI 面板的 AX 树 System Events 枚举不了**（`entire contents` 报 -1700）：自动化输入走 `AXUIElement` API 直写（`AXUIElementCopyAttributeValue(kAXWindowsAttribute)` → 递归找 `AXTextField` → `SetAttributeValue(kAXValueAttribute)`），比模拟键盘安全（不落错目标）；截图用 `screencapture -l<窗口ID>` 只截目标窗口，避免把用户桌面其他窗口截进来。用户正在使用机器时，避免真实键鼠注入与触发会弹窗口的动作。
11. **xcodegen 配 unit-test target 的三个坑**（2026-10-22 实撞）：① 测试 target 与 app target 的 swiftmodule 安装路径撞车（`Multiple commands produce OpenMyApp.swiftmodule`）——必须显式设 `PRODUCT_NAME` / `PRODUCT_MODULE_NAME` 为 `OpenMyAppTests`；② `@testable import OpenMyApp` 只在宿主模式（TEST_HOST + BUNDLE_LOADER）可用，且宿主模式正是 swiftmodule 冲突的来源——现在的 logic bundle 模式下被测源码直接编进测试 bundle，测试文件**不要 import**，类型同模块可见（`@testable import` 在本地能过是旧派生数据里有 app swiftmodule 掩盖的假象——CI 全新检出必挂，v1.4.0 首跑 CI 实撞）；③ xcodegen 会给 unit-test target 自动注入 `BUNDLE_LOADER = $(TEST_HOST)`（TEST_HOST 为空），无害，但排查构建问题时别被它误导。AppDelegate 顶部有 XCTest 环境守卫（宿主模式下跳过全部启动副作用），将来加集成测试可直接复用。
