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
- **Launchpad-style app grid**: summon the panel with an empty query to browse all installed apps as an icon grid (7 columns, scrollable), sorted by most used; ←/→/↑/↓ move the selection, Return launches it
- **Terminal & Finder commands**: type `t <name>` (or `terminal <name>`) to open a matching folder in Terminal, `o <name>` (or `open <name>`) to open a file or folder in Finder (Spotlight-backed, home directory, top 5 hits, debounced). Exact name matches rank first, then prefix matches, then substring matches; prefix the keyword with `/` to match names starting with it and/or trail it with `/` to match names ending with it (e.g. `t /google`, `t google/`). The built-in words are fallbacks: binding a custom app to `terminal` or `open` in Folder Commands redirects their aliases (`t` / `o`) to that app too
- **Custom folder commands**: bind any prefix to any installed app in Settings → Custom Folder Commands (e.g. `zcode` → iTerm). Type `zcode <name>` — or a unique abbreviation like `z <name>` — to search folders and open the selected one with that app; its icon and name show up in the results
- **Clipboard history**: every copy (text, images, files from Finder) is captured into a local SQLite database. Search results mix in clipboard hits (top 3 per source); Return writes the item back to the clipboard and auto-pastes it into the frontmost app (asks for Accessibility permission, copy-only until granted). Large texts and images are stored as files with references in the database, big images get fast downsampled thumbnails, duplicates merge into one entry, and low-usage records older than a configurable number of days are cleaned up daily (retention days and usage threshold configurable in Settings → Clipboard). All local — nothing ever leaves the machine
- **Clipboard mode**: ⌘⇧V (customizable) opens the panel in clipboard-only mode showing the most recent records; search matches across the in-memory cache first, then the full database (whitespace-split tokens, case-insensitive, FTS5-indexed full text)
- **Bilingual UI**: English and 简体中文, follows the system language
- **In-app updates**: Settings → Check for Updates downloads and installs new releases automatically
- **Launch at login**: enabled by default on first launch; turn it off anytime in Settings (based on SMAppService)
- Fully local: **no network requests, no data collection**

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌥ Space (default, customizable in Settings) | Summon / dismiss the search panel |
| ⌘⇧ V (default, customizable in Settings) | Open the panel in clipboard-only mode |
| ↑ / ↓ | Move between results |
| ↩ | Open the selected item (first hit by default); clipboard items are copied and auto-pasted |
| Esc | Dismiss the panel and clear the query |
| ⌘ A | Select all text in the search box |
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
