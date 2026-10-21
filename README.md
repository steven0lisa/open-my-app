# OpenMyApp

[English](README.md) | [中文](README.zh-CN.md)

A Spotlight-style minimalist app launcher for macOS: hit ⌥Space to summon a floating search box, type a pinyin or English name to search local applications and System Settings panes, then press Return to open the top hit.

![license](https://img.shields.io/badge/license-Apache--2.0-blue)

## Features

- **Pinyin search**: type `fangda` or `fd` to find Finder; English names like `finder` work too
- **Direct access to System Settings**: search `sound`, `shengyin`, or `声音` to open the matching settings pane
- **Spotlight-style UI**: frosted-glass floating panel shown on launch; ↑/↓ to select, Return to open the top hit
- **Auto-hide on outside click**; Esc dismisses as well
- **Menu bar resident**, with an option to hide the menu bar icon to save space (the global hotkey still works while hidden)
- **Customizable hotkey**: record a new key combination in Settings (⌥Space by default)
- **Automatic app discovery**: FSEvents watches application folders, so newly installed apps get indexed without a restart
- **Extremely low resource usage**: 0% CPU at idle (no timers, no polling; event monitors are mounted only while the panel is visible), ~29MB physical memory, <0.1ms per search
- **Usage-based ranking**: frequently launched apps float to the top
- **Terminal & Finder commands**: type `t <name>` (or `terminal <name>`) to open a matching folder in Terminal, `o <name>` (or `open <name>`) to open a file or folder in Finder (Spotlight-backed, home directory, top 5 hits, debounced)
- **Bilingual UI**: English and 简体中文, follows the system language
- **In-app updates**: Settings → Check for Updates downloads and installs new releases automatically
- **Launch at login**: toggle in Settings (based on SMAppService)
- Fully local: **no network requests, no data collection**

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌥ Space (default, customizable in Settings) | Summon / dismiss the search panel |
| ↑ / ↓ | Move between results |
| ↩ | Open the selected item (first hit by default) |
| Esc | Dismiss the panel and clear the query |
| ⌘ , | Open Settings |

## Requirements

- macOS 15.0+

## Build Locally

```bash
# 1. Generate the Xcode project (requires xcodegen: brew install xcodegen)
xcodegen generate

# 2a. Open in Xcode to build / debug
open OpenMyApp.xcodeproj

# 2b. Or build from the command line
xcodebuild -project OpenMyApp.xcodeproj -scheme OpenMyApp -configuration Debug -derivedDataPath build build

# Regenerate the app icon (optional; run after editing scripts/generate-icon.swift)
swift scripts/generate-icon.swift
```

## Release Process

The version number is managed centrally in the `VERSION` file; `bump-version.sh` syncs it to `package.json` and `project.yml`:

```bash
# 1. Bump the version
./scripts/bump-version.sh patch   # 1.0.0 → 1.0.1 (minor / major likewise)

# 2. Commit and tag
git add -A && git commit -m 'chore: bump version to x.y.z'
git tag vx.y.z

# 3. Push (GitHub Actions builds the DMG and creates the Release)
git push origin main --tags
```

When a `v*` tag is pushed, GitHub Actions (`.github/workflows/release.yml`) automatically runs a sensitive-data scan → xcodegen → xcodebuild Release → ad-hoc signing → packages the DMG → creates a GitHub Release with the DMG attached.

If Gatekeeper blocks the app on first launch from a downloaded DMG, right-click → Open.

## Sensitive Data Rules

Run `./scripts/check-sensitive.sh` before pushing to GitHub: hits on credentials, company names, internal domains, or webhooks fail the check and block the push; emails, local paths, and real names are flagged for manual review. The CI release workflow runs the same scan before building as a safety net.

## License

Apache License 2.0
