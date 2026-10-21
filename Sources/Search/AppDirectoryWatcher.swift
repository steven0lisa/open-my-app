import CoreServices
import Foundation

/// 监听应用目录变化（新装 / 删除应用），FSEvents 实现，去抖后回调主线程
final class AppDirectoryWatcher {
    /// 目录变化（已去抖），主线程回调
    var onChange: (() -> Void)?

    private let directories: [String]
    private var stream: FSEventStreamRef?
    private var pendingWork: DispatchWorkItem?
    /// 安装器会连续产生多条事件，去抖后只通知一次
    private let debounceInterval: TimeInterval = 1.5

    init(directories: [String]) {
        self.directories = directories
    }

    deinit {
        stop()
    }

    func start() {
        // FSEvents 只监听当前已存在的目录（/Applications 恒存在；~/Applications 可能不存在）
        let existing = directories.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty, stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<AppDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.scheduleNotification()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else {
            NSLog("[OpenMyApp] FSEventStreamCreate failed")
            return
        }
        self.stream = stream
        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        FSEventStreamStart(stream)
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        pendingWork?.cancel()
        pendingWork = nil
    }

    private func scheduleNotification() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
