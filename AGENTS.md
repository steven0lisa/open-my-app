# AGENTS.md

本文件供 AI 编码助手在本仓库工作时参考。

## 项目概述

OpenMyApp 是一个 macOS 极简应用启动器（SwiftUI + AppKit，无第三方依赖）。核心交互仿 Alfred：启动即显示悬浮搜索框，输入拼音 / 英文名搜索本机应用程序与系统设置面板，回车打开第一项；点击面板外自动隐藏；菜单栏常驻且可隐藏图标。

## 常用命令

```bash
xcodegen generate          # 生成 Xcode 工程（工程文件 *.xcodeproj 不入库）
xcodebuild -project OpenMyApp.xcodeproj -scheme OpenMyApp -configuration Debug -derivedDataPath build build
swift scripts/generate-icon.swift   # 重新生成应用图标
./scripts/bump-version.sh patch     # 升级版本号（同步 VERSION / package.json / project.yml）
./scripts/check-sensitive.sh        # 敏感信息扫描
```

## 源码结构（Sources/）

| 目录 | 职责 | 关键类型 |
|------|------|----------|
| `App/` | 入口、生命周期、悬浮面板窗口、托盘 | `AppDelegate`, `PanelController`, `StatusBarController`, `main.swift` |
| `Search/` | 数据源与检索 | `AppIndexer`（扫 /Applications 等）、`SystemSettingsCatalog`（设置面板锚点）、`Pinyin`（CFStringTransform 转拼音）、`SearchEngine`（打分排序） |
| `UI/` | 界面 | `LauncherView` / `LauncherModel`（搜索框 + 结果列表）、`SettingsWindow`、`VisualEffectBackground` |
| `Hotkey/` | 全局快捷键 | `HotkeyManager`（Carbon RegisterEventHotKey，无需辅助功能权限）、`HotkeyDisplay`（keyCode+掩码 ↔ "⌥Space" 展示互转） |
| `Utils/` | 偏好与使用频次 | `Preferences` |

## 关键设计

- 悬浮面板是 `NSPanel`（`.nonactivatingPanel` + `becomesKeyOnlyFirstResponder`），不抢当前应用焦点；`NSHostingController.sizingOptions = [.preferredContentSize]` 让窗口随结果数量伸缩，`windowDidResize` 保持顶边不动。
- 点击面板外隐藏 = 全局鼠标监听（其他应用）+ 本地鼠标监听（本应用其他窗口）双通道。
- 系统设置面板通过 `x-apple.systempreferences:<扩展锚点>` 打开（macOS 13+），锚点清单在 `SystemSettingsCatalog`。
- 中文搜索：应用本地化名经 `kCFStringTransformMandarinLatin` + 去声调得到全拼与首字母，配合原名 / 英文名打分（前缀 > 包含 > 子序列），再叠加使用频次加权。系统语言非中文时，第三方应用读 bundle 内 `zh_CN.lproj/InfoPlist.strings` 强制取中文名；系统应用资源在 dyld 共享缓存中读不到，用 `AppIndexer.zhNameOverrides` 静态对照表兜底。
- 索引新鲜度双通道：面板每次显示时后台重扫（`LauncherModel.prepare()`），同时 `AppDirectoryWatcher` 用 FSEvents 监听 `AppIndexer.searchDirectories`（只监听启动时已存在的目录），去抖 1.5s 后触发 `PanelController.rescanIndex()`，面板隐藏时也会更新索引。
- 全局快捷键可在设置页自定义：偏好存 keyCode + Carbon 修饰键掩码（`Preferences.hotkeyKeyCode/hotkeyCarbonMask`），设置页 `HotkeyRecorderButton` 录制（要求 ⌘/⌥/⌃ 至少一个），变更经 `SettingsWindowController.onPreferenceChanged` 触发 `HotkeyManager.reRegister()` 与托盘刷新。
- 应用名称用 `FileManager.displayName(atPath:)` 取本地化名（中文系统返回中文名）。

## 发布流程

1. `./scripts/bump-version.sh patch|minor|major`（三文件同步）
2. 提交 → `git tag vx.y.z` → 推送，GitHub Actions 自动构建 DMG 并发 Release
3. 版本日志写在 `package.json` 的 `releaseHistory` 中

## 敏感信息规则（强制）

- **推送 GitHub 前必须跑 `./scripts/check-sensitive.sh`**：FAIL 项（凭据 / 公司名 / 内网域名 / webhook / 带密码连接串）必须删除或替换为占位符；WARN 项（邮箱 / 本机绝对路径 / 真实姓名 / 手机号）人工确认。
- 本仓库 git 身份必须使用 GitHub noreply 邮箱（`git config user.email`），**禁止公司邮箱**；提交后可用 `git log -1 --format='%an <%ae>'` 自检。
- CI（release.yml）在构建前会再跑一次同样的扫描作为兜底。
- `.v2c/`、`.findings/`、`build/`、`dist/` 等本地目录已入 `.gitignore`，不要 `git add -A` 后不过目直接提交。
