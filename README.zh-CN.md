# OpenMyApp

[English](README.md) | [中文](README.zh-CN.md)

Spotlight 风格的 macOS 极简应用启动器：按 ⌥Space 唤出搜索框，输入拼音或英文名即可搜索本机应用程序与系统设置面板，回车直达。

![license](https://img.shields.io/badge/license-Apache--2.0-blue)

## 功能特性

- **拼音搜索**：输入 `fangda`、`fd` 找到「访达」，输入英文名如 `finder` 同样可搜
- **直达系统设置**：搜索 `声音`、`shengyin`、`sound` 均可直接打开对应设置面板
- **Spotlight 风格 UI**：毛玻璃悬浮面板，启动即显示，上下键选择、回车打开第一项
- **点击面板外自动隐藏**，Esc 也可关闭
- **菜单栏常驻**，可在菜单中选择隐藏图标以节省菜单栏空间（隐藏后仍可用快捷键唤出）
- **快捷键可自定义**：设置页点击按钮录制新组合键（默认 ⌥Space）
- **自动发现新应用**：FSEvents 监听应用目录，安装新应用后索引自动更新，无需重启
- **极低资源占用**：空闲 0% CPU（无定时器、无轮询；事件监听仅面板可见时挂载），物理内存 ~29MB，单次搜索 <0.1ms
- **常用加权**：启动过的应用会按使用频次自动排在前面
- **Terminal / Finder 命令**：`t <名称>` 用 Terminal 打开匹配目录，`o <名称>` 用 Finder 打开文件 / 目录（Spotlight 驱动，HOME 范围，最多 5 条，输入防抖）
- **界面双语**：英文 / 简体中文，跟随系统语言
- **应用内更新**：设置 → 检查更新，可自动下载并安装新版本
- **登录自启动**：设置窗口中可开启（基于 SMAppService）
- 纯本地运行，**无任何网络请求、无数据收集**

## 快捷键

| 快捷键 | 作用 |
|--------|------|
| ⌥ Space（默认，可在设置中自定义） | 全局唤出 / 隐藏搜索框 |
| ↑ / ↓ | 在结果间移动 |
| ↩ | 打开选中项（默认第一项） |
| Esc | 关闭面板并清空搜索 |
| ⌘ , | 打开设置 |

## 系统要求

- macOS 15.0+

## 本地构建

```bash
# 1. 生成 Xcode 工程（需要 xcodegen：brew install xcodegen）
xcodegen generate

# 2a. 用 Xcode 打开构建 / 调试
open OpenMyApp.xcodeproj

# 2b. 或命令行构建
xcodebuild -project OpenMyApp.xcodeproj -scheme OpenMyApp -configuration Debug -derivedDataPath build build

# 重新生成应用图标（可选，改 scripts/generate-icon.swift 后执行）
swift scripts/generate-icon.swift
```

## 发布流程

版本号统一由 `VERSION` 文件管理，`bump-version.sh` 自动同步 `package.json` 与 `project.yml`：

```bash
# 1. 升级版本号
./scripts/bump-version.sh patch   # 1.0.0 → 1.0.1（minor / major 同理）

# 2. 提交并打 tag
git add -A && git commit -m 'chore: bump version to x.y.z'
git tag vx.y.z

# 3. 推送（触发 GitHub Actions 自动构建 DMG 并创建 Release）
git push origin main --tags
```

GitHub Actions（`.github/workflows/release.yml`）在 `v*` tag 推送时自动：敏感信息扫描 → xcodegen → xcodebuild Release → ad-hoc 签名 → 打包 DMG → 创建 GitHub Release 并上传 DMG。

首次打开 DMG 安装的应用如被 Gatekeeper 拦截，右键 →「打开」即可。

## 敏感信息规则

推送 GitHub 前必须运行 `./scripts/check-sensitive.sh`：命中凭据、公司信息、webhook 等会直接 FAIL 阻止推送；邮箱 / 本机路径 / 真实姓名等会提示人工确认。CI 发版流程在构建前也会再跑一次同样扫描。

## 许可证

Apache License 2.0
