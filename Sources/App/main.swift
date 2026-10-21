import AppKit

// 顶层代码运行在主线程，用 assumeIsolated 满足 @MainActor 标注的 AppDelegate
let delegate = MainActor.assumeIsolated {
    AppDelegate()
}
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
