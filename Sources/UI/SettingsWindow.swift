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

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(
                    onPreferenceChanged: { [weak self] in self?.onPreferenceChanged?() }
                )
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = NSLocalizedString("OpenMyApp Settings", comment: "settings window title")
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 520, height: 520))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    var onPreferenceChanged: () -> Void

    @StateObject private var updater = UpdateChecker()
    @State private var showMenuBarIcon = Preferences.showMenuBarIcon
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemsError: String?
    @State private var clipboardAXTrusted = false

    var body: some View {
        Form {
            Section(NSLocalizedString("General", comment: "settings section")) {
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

            Section(NSLocalizedString("Hotkey", comment: "settings section")) {
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

            Section(NSLocalizedString("Clipboard", comment: "settings section")) {
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
                Text(NSLocalizedString(
                    "Copied text, images and files are stored locally in SQLite. Low-usage records older than a week are cleaned up automatically.",
                    comment: "clipboard footnote"
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("About", comment: "settings section")) {
                LabeledContent(NSLocalizedString("Version", comment: "about"), value: Self.appVersion)
                LabeledContent(
                    NSLocalizedString("Tagline", comment: "about"),
                    value: NSLocalizedString("A minimalist launcher: pinyin search for apps & System Settings", comment: "")
                )
                updateRow
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
        .onAppear { clipboardAXTrusted = AXIsProcessTrusted() }
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
