import AppKit
import Carbon.HIToolbox
import SwiftUI
import ServiceManagement
import ApplicationServices

/// 设置窗口控制器（懒创建、单例窗口）
@MainActor
final class SettingsWindowController: NSObject {
    /// 偏好变化后回调（如刷新托盘图标、重注册快捷键）
    var onPreferenceChanged: (() -> Void)?
    /// 剪切板清理参数变化后回调（立即执行一次清理让新参数生效）
    var onClipboardCleanupChanged: (() -> Void)?

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(
                    onPreferenceChanged: { [weak self] in self?.onPreferenceChanged?() },
                    onClipboardCleanupChanged: { [weak self] in self?.onClipboardCleanupChanged?() }
                )
            )
            // 窗口尺寸由 SwiftUI 内容决定：切 Tab 时高度随内容变化，避免大片留白
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = NSLocalizedString("OpenMyApp Settings", comment: "settings window title")
            window.styleMask = [.titled, .closable]
            // SwiftUI 布局完成前的初始兜底尺寸；显示后被 preferredContentSize 接管
            window.setContentSize(NSSize(width: 520, height: 250))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 设置页 Tab：segmented 切换条 + 每个 Tab 按内容给定窗口高度
/// （不用 TabView——它在 macOS 上的默认样式与窗口标题栏之间有空带、
///  tab 条四周留白怪异，实测观感很差）
private enum SettingsTab: Int, CaseIterable, Identifiable {
    case general, hotkeys, commands, clipboard, about

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .general: return NSLocalizedString("General", comment: "settings tab")
        case .hotkeys: return NSLocalizedString("Hotkeys", comment: "settings tab")
        case .commands: return NSLocalizedString("Folder Commands", comment: "settings tab")
        case .clipboard: return NSLocalizedString("Clipboard", comment: "settings tab")
        case .about: return NSLocalizedString("About", comment: "settings tab")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .hotkeys: return "command"
        case .commands: return "folder"
        case .clipboard: return "doc.on.clipboard"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    var onPreferenceChanged: () -> Void
    /// 剪切板清理参数（保留天数 / 次数阈值）变化后回调
    var onClipboardCleanupChanged: () -> Void

    @StateObject private var updater = UpdateChecker()
    @State private var showMenuBarIcon = Preferences.showMenuBarIcon
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemsError: String?
    @State private var clipboardAXTrusted = false
    @State private var customCommands: [CustomAppCommand] = Preferences.customAppCommands
    @State private var installedApps: [IndexedApp] = []
    @State private var cleanupRetentionDays = Preferences.clipboardRetentionDays
    @State private var cleanupKeepUsageCount = Preferences.clipboardKeepUsageCount
    @State private var tab: SettingsTab = .general

    /// 窗口高度跟随当前 Tab 的内容量（NSHostingController.preferredContentSize 接管窗口尺寸）
    private var contentHeight: CGFloat {
        switch tab {
        case .general:
            return showMenuBarIcon ? 190 : 250
        case .hotkeys:
            return 330
        case .commands:
            // 命令行数增长时 Form 内部滚动，窗口高度封顶
            return min(160 + CGFloat(customCommands.count) * 52, 420)
        case .clipboard:
            return clipboardAXTrusted ? 355 : 395
        case .about:
            return 230
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(NSLocalizedString("Settings", comment: "settings tab a11y"), selection: $tab) {
                ForEach(SettingsTab.allCases) { item in
                    Label(item.title, systemImage: item.systemImage).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 2)

            Group {
                switch tab {
                case .general: generalTab
                case .hotkeys: hotkeysTab
                case .commands: commandsTab
                case .clipboard: clipboardTab
                case .about: aboutTab
                }
            }
        }
        .frame(width: 520, height: contentHeight, alignment: .top)
        .onAppear { clipboardAXTrusted = AXIsProcessTrusted() }
        .onAppear {
            // 应用目录在后台扫一次（含 bundle 中文名提取，主线程扫会卡顿一下）
            guard installedApps.isEmpty else { return }
            Task.detached(priority: .userInitiated) {
                let apps = AppIndexer.scan().sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                await MainActor.run { installedApps = apps }
            }
        }
        .onChange(of: customCommands) { _, newValue in
            Preferences.customAppCommands = newValue
            onPreferenceChanged()
        }
    }

    // MARK: - 通用

    private var generalTab: some View {
        Form {
            Section {
                Toggle(NSLocalizedString("Launch at Login", comment: "setting"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLoginItem(enabled: enabled)
                    }
                Toggle(NSLocalizedString("Show Menu Bar Icon", comment: "setting"), isOn: $showMenuBarIcon)
                    .onChange(of: showMenuBarIcon) { _, enabled in
                        Preferences.showMenuBarIcon = enabled
                        onPreferenceChanged()
                    }
                if !showMenuBarIcon {
                    Text(String(
                        format: NSLocalizedString(
                            "Menu bar icon is hidden: summon the panel with %@ and click the ⚙ button to reopen Settings.",
                            comment: ""
                        ),
                        Preferences.hotkeyDisplay
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if let loginItemsError {
                    Text(String(
                        format: NSLocalizedString("Failed to update login items: %@", comment: ""),
                        loginItemsError
                    ))
                    .font(.footnote)
                    .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 快捷键

    private var hotkeysTab: some View {
        Form {
            Section {
                HotkeyRecorderButton(
                    label: NSLocalizedString("Summon / Dismiss Panel", comment: "shortcut"),
                    readDisplay: { Preferences.hotkeyDisplay },
                    write: { keyCode, mask in
                        Preferences.hotkeyKeyCode = keyCode
                        Preferences.hotkeyCarbonMask = Int(mask)
                    }
                ) { onPreferenceChanged() }
                HotkeyRecorderButton(
                    label: NSLocalizedString("Open Clipboard Mode", comment: "shortcut"),
                    readDisplay: { Preferences.clipboardHotkeyDisplay },
                    write: { keyCode, mask in
                        Preferences.clipboardHotkeyKeyCode = keyCode
                        Preferences.clipboardHotkeyCarbonMask = Int(mask)
                    }
                ) { onPreferenceChanged() }
                LabeledContent(NSLocalizedString("Move Between Results", comment: "shortcut"), value: "↑ / ↓")
                LabeledContent(NSLocalizedString("Open Selected Item", comment: "shortcut"), value: "↩")
                LabeledContent(NSLocalizedString("Dismiss Panel", comment: "shortcut"), value: NSLocalizedString("Esc / click outside", comment: "shortcut"))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 目录命令

    private var commandsTab: some View {
        Form {
            Section {
                Text(NSLocalizedString(
                    "Type a prefix followed by a keyword to search folders; Return opens the best match with the chosen app. A unique abbreviation of the prefix works too (e.g. \"z\" for \"zcode\").",
                    comment: "custom folder commands footnote"
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)

                ForEach($customCommands) { $command in
                    CustomCommandRow(command: $command, apps: installedApps) {
                        customCommands.removeAll { $0.id == command.id }
                    }
                }

                Button {
                    customCommands.append(CustomAppCommand(id: UUID(), prefix: "", appName: "", appPath: ""))
                } label: {
                    Label(NSLocalizedString("Add Command", comment: "custom folder commands"), systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 剪切板

    private var clipboardTab: some View {
        Form {
            Section {
                if clipboardAXTrusted {
                    Label(
                        NSLocalizedString("Auto-paste enabled: selecting a clipboard item pastes it into the frontmost app.", comment: "clipboard permission"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    Label(
                        NSLocalizedString("Auto-paste needs Accessibility permission; until granted, selecting only copies to the clipboard.", comment: "clipboard permission"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.secondary)
                    Button(NSLocalizedString("Grant Accessibility Permission…", comment: "clipboard permission")) {
                        SystemSettingsCatalog.open(anchor: "com.apple.settings.privacy?Privacy_Accessibility")
                    }
                }
            }

            Section {
                Stepper(value: $cleanupRetentionDays, in: 1...365) {
                    LabeledContent(NSLocalizedString("Clean up records older than", comment: "clipboard cleanup")) {
                        Text(String(format: NSLocalizedString("%d days", comment: "days count"), cleanupRetentionDays))
                    }
                }
                .onChange(of: cleanupRetentionDays) { _, newValue in
                    Preferences.clipboardRetentionDays = newValue
                    onClipboardCleanupChanged()
                }
                Stepper(value: $cleanupKeepUsageCount, in: 1...10) {
                    LabeledContent(NSLocalizedString("Only if used fewer than", comment: "clipboard cleanup")) {
                        Text(String(format: NSLocalizedString("%d times", comment: "uses count"), cleanupKeepUsageCount))
                    }
                }
                .onChange(of: cleanupKeepUsageCount) { _, newValue in
                    Preferences.clipboardKeepUsageCount = newValue
                    onClipboardCleanupChanged()
                }
                Text(String(
                    format: NSLocalizedString(
                        "Records older than %1$d days with fewer than %2$d uses are removed automatically; everything else is kept forever.",
                        comment: "clipboard cleanup footnote"
                    ),
                    cleanupRetentionDays,
                    cleanupKeepUsageCount
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                Text(NSLocalizedString(
                    "Copied text, images and files are stored locally in SQLite.",
                    comment: "clipboard footnote"
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 关于

    private var aboutTab: some View {
        Form {
            Section {
                LabeledContent(NSLocalizedString("Version", comment: "about"), value: Self.appVersion)
                LabeledContent(
                    NSLocalizedString("Tagline", comment: "about"),
                    value: NSLocalizedString("A minimalist launcher: pinyin search for apps & System Settings", comment: "")
                )
                updateRow
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 更新

    @ViewBuilder
    private var updateRow: some View {
        HStack(spacing: 10) {
            switch updater.state {
            case .idle, .upToDate, .failed:
                Button(NSLocalizedString("Check for Updates", comment: "update")) {
                    Task { await updater.checkForUpdates() }
                }
            case .checking:
                ProgressView()
                    .controlSize(.small)
                Text(NSLocalizedString("Checking…", comment: "update"))
                    .foregroundStyle(.secondary)
            case .available(let version):
                Text(String(
                    format: NSLocalizedString("New version %@ available", comment: "update"),
                    version
                ))
                Button(NSLocalizedString("Download & Install", comment: "update")) {
                    Task { await updater.downloadAndInstall() }
                }
                .buttonStyle(.borderedProminent)
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(maxWidth: 160)
                Text(String(
                    format: NSLocalizedString("Downloading… %d%%", comment: "update"),
                    Int(fraction * 100)
                ))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            case .installing:
                ProgressView()
                    .controlSize(.small)
                Text(NSLocalizedString("Installing… the app will restart", comment: "update"))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            switch updater.state {
            case .upToDate:
                Text(NSLocalizedString("You're up to date", comment: "update"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    private func setLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemsError = nil
        } catch {
            loginItemsError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// 自定义目录命令的单行配置：前缀输入框 → 应用下拉框（每项带图标与名字）→ 删除按钮
private struct CustomCommandRow: View {
    @Binding var command: CustomAppCommand
    /// 已安装应用目录（后台扫描异步到达，初始为空）
    let apps: [IndexedApp]
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(
                NSLocalizedString("Prefix", comment: "custom folder commands"),
                text: $command.prefix
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 110)
            .autocorrectionDisabled()

            Image(systemName: "arrow.right")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            appPicker

            Spacer(minLength: 0)

            Button(action: onRemove) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("Remove Command", comment: "custom folder commands"))
        }
    }

    /// 应用选择下拉框。选中值按 appPath 存储；若绑定的应用已被卸载（不在扫描结果里），
    /// 以存储的路径补一个选项，避免下拉框把已有绑定显示成空白
    private var appPicker: some View {
        Picker(
            NSLocalizedString("App", comment: "custom folder commands"),
            selection: Binding(
                get: { command.appPath },
                set: { newPath in
                    command.appPath = newPath
                    if let app = apps.first(where: { $0.path == newPath }) {
                        command.appName = app.name
                    } else {
                        command.appName = ((newPath as NSString).lastPathComponent as NSString).deletingPathExtension
                    }
                }
            )
        ) {
            Text(NSLocalizedString("Choose an app…", comment: "custom folder commands")).tag("")
            ForEach(displayApps, id: \.path) { app in
                Label {
                    Text(app.name)
                } icon: {
                    Image(nsImage: Self.icon(for: app.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .tag(app.path)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 240)
    }

    private var displayApps: [IndexedApp] {
        guard !command.appPath.isEmpty, !apps.contains(where: { $0.path == command.appPath }) else {
            return apps
        }
        let name = command.appName.isEmpty
            ? ((command.appPath as NSString).lastPathComponent as NSString).deletingPathExtension
            : command.appName
        return [IndexedApp(path: command.appPath, name: name, chineseName: nil, englishName: name)] + apps
    }

    private static func icon(for path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}

/// 自定义快捷键录制控件：点击进入录制态，下一个组合键即生效；Esc 取消。
/// 通过 readDisplay / write 闭包绑定任意一组快捷键偏好（主热键 / 剪切板热键）
private struct HotkeyRecorderButton: View {
    let label: String
    let readDisplay: () -> String
    let write: (Int, UInt32) -> Void
    /// 录制成功后回调
    var onChange: () -> Void

    @State private var isRecording = false
    @State private var errorMessage: String?
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            LabeledContent {
                Button {
                    isRecording = true
                } label: {
                    Text(isRecording ? NSLocalizedString("Press a new shortcut…", comment: "hotkey recorder") : readDisplay())
                        .monospaced()
                        .frame(minWidth: 90)
                }
                .buttonStyle(.bordered)
                .disabled(isRecording)
            } label: {
                Text(label)
            }

            if isRecording {
                Text(NSLocalizedString("Press the new combination to apply, Esc to cancel", comment: "hotkey recorder"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: isRecording) { _, recording in
            if recording { startListening() } else { stopListening() }
        }
        .onDisappear { stopListening() }
    }

    private func startListening() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyEvent(event)
        }
    }

    private func stopListening() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// 返回 nil 表示按键已被录制消费
    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }

        // Esc 取消录制
        if event.keyCode == 53 {
            isRecording = false
            errorMessage = nil
            return nil
        }

        let mask = HotkeyDisplay.carbonMask(from: event.modifierFlags)
        let hasRequiredModifier = mask & UInt32(cmdKey | optionKey | controlKey) != 0
        guard hasRequiredModifier else {
            errorMessage = NSLocalizedString("Include at least one of ⌘ / ⌥ / ⌃", comment: "hotkey recorder")
            return nil
        }

        write(Int(event.keyCode), mask)
        errorMessage = nil
        isRecording = false
        onChange()
        return nil
    }
}
