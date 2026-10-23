import AppKit
import CryptoKit
import ImageIO
import ApplicationServices

/// 剪切板中枢：后台 1s 轮询粘贴板 changeCount（系统无变更通知，只能轮询；
/// 只读计数不读内容，功耗可忽略），捕获新内容落库，维护最近 200 条内存缓存，
/// 并提供内存优先 + 数据库异步的双层搜索与选中回写/自动粘贴。
///
/// 线程约定（Swift 5 语言模式，未用 actor）：
/// - 主线程：memory 数组、public API（LauncherModel/PanelController 调用）
/// - workQueue：轮询、内容捕获、落盘、DB 查询、清理
/// - 主线程与 workQueue 的字段各自独占；suppressedChangeCount 经 workQueue.async
///   写入保证 happens-before
final class ClipboardManager {
    private let store: ClipboardStore
    private let filesDirectory: URL
    private let workQueue = DispatchQueue(label: "com.openmyapp.clipboard", qos: .utility)
    private var pollTimer: DispatchSourceTimer?
    /// 轮询线程独占
    private var lastSeenChangeCount = 0
    /// 应用自己回写产生的 changeCount，轮询时跳过（否则选中记录会把自己再捕获一遍）
    /// 轮询线程独占（主线程经 workQueue.async 写入）
    private var suppressedChangeCount = -1
    /// 轮询线程独占
    private var nextCleanupDue = Date.distantFuture
    private var axPromptShown = false

    /// 内存缓存条目：记录 + 预计算的小写检索文本。
    /// 小写文本必须预计算——搜索热路径每条每键现算 lowercase 的话，200 条 × ≤16KB
    /// 内容 = 每次按键 ~2ms 主线程耗时 + MB 级临时字符串分配（真实数据基准 1.92ms → 0.16ms）
    private struct MemoryEntry {
        let item: ClipboardItem
        let searchTextLower: String
    }

    /// 最近记录缓存（新→旧），仅主线程访问；超出 ClipboardLimits.memoryCapacity 淘汰
    private var memory: [MemoryEntry] = []

    static var storageRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("OpenMyApp", isDirectory: true)
    }

    init() {
        filesDirectory = Self.storageRoot.appendingPathComponent("clipboard-files", isDirectory: true)
        store = ClipboardStore(directory: Self.storageRoot)
        memory = store.recentItems(limit: ClipboardLimits.memoryCapacity).map(Self.makeEntry)
        NSLog("[OpenMyApp] 剪切板缓存装载: \(memory.count) 条 (fts=\(store.ftsAvailable))")
    }

    private static func makeEntry(_ item: ClipboardItem) -> MemoryEntry {
        MemoryEntry(item: item, searchTextLower: item.searchTextLower)
    }

    /// 应用启动时调用：开始轮询与每日清理调度
    func start() {
        guard pollTimer == nil else { return }
        workQueue.async { [weak self] in
            guard let self else { return }
            self.lastSeenChangeCount = NSPasteboard.general.changeCount
            self.nextCleanupDue = Self.nextCleanupDate(after: Date())
        }
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.pollOnce()
        }
        timer.resume()
        pollTimer = timer
    }

    /// 清理一天最多跑一次；错过（应用未运行）则启动后补跑
    private static func nextCleanupDate(after date: Date) -> Date {
        let last = Preferences.clipboardLastCleanupAt
        let next = Date(timeIntervalSince1970: last + 24 * 3600)
        return next > date ? next : date
    }

    /// 清理参数（设置页）变更后立即执行一次，让新参数即时生效。
    /// 在 workQueue 执行，与 pollOnce 的清理记账（nextCleanupDue / lastCleanupAt）同队列互斥
    func cleanNow() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.nextCleanupDue = Date().addingTimeInterval(24 * 3600)
            Preferences.clipboardLastCleanupAt = Date().timeIntervalSince1970
            _ = self.store.cleanupOld(
                retentionDays: Preferences.clipboardRetentionDays,
                keepUsageCount: Preferences.clipboardKeepUsageCount
            )
        }
    }

    // MARK: - 轮询与捕获（workQueue）

    private func pollOnce() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastSeenChangeCount, count != suppressedChangeCount else { return }
        lastSeenChangeCount = count

        if Date() >= nextCleanupDue {
            nextCleanupDue = Date().addingTimeInterval(6 * 3600)
            Preferences.clipboardLastCleanupAt = Date().timeIntervalSince1970
            _ = store.cleanupOld(
                retentionDays: Preferences.clipboardRetentionDays,
                keepUsageCount: Preferences.clipboardKeepUsageCount
            )
        }

        guard let records = Self.capture(pasteboard: pasteboard, filesDirectory: filesDirectory) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.commit(records)
        }
    }

    /// 读取粘贴板内容并落盘（图片 / 大文本写文件），返回待入库记录；无有效内容返回 nil。
    /// 类型优先级：文件引用（Finder 复制）> 图片 > 文本。
    static func capture(pasteboard: NSPasteboard, filesDirectory: URL) -> [ClipboardStore.NewRecord]? {
        try? FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)

        // 1. 文件引用：Finder 复制文件只记录完整路径（多条各存一条）
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.prefix(ClipboardLimits.maxFilesPerCapture).map { url -> ClipboardStore.NewRecord in
                let path = url.path
                let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
                return ClipboardStore.NewRecord(
                    type: .file,
                    preview: path,
                    content: nil,
                    filePath: path,
                    thumbPath: nil,
                    byteSize: size,
                    searchText: path,
                    hash: ClipboardStore.contentHash("file:", Data(path.utf8)),
                    createdAt: Date()
                )
            }
        }

        // 2. 图片：统一转 PNG 落盘（粘贴板 TIFF 是无压缩位图，体积虚高）
        if let tiff = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png),
           let png = Self.normalizedPNG(from: tiff), png.count < 256 * 1024 * 1024 {
            let hash = ClipboardStore.contentHash("image:", png)
            let imagePath = filesDirectory.appendingPathComponent("\(hash).png").path
            try? png.write(to: URL(fileURLWithPath: imagePath))
            // 缩略图双阈值：字节数大，或字节数小但像素尺寸大（高分辨率截图 PNG 压缩率高，
            // 不设尺寸阈值的话行渲染时会整图解码，几十 MB 解码内存一闪而过）
            var needsThumb = png.count > ClipboardLimits.imageThumbBytes
            if !needsThumb, let size = Self.pngPixelSize(png) {
                needsThumb = max(size.width, size.height) > ClipboardLimits.thumbMaxPixel * 2
            }
            var thumbPath: String?
            if needsThumb {
                thumbPath = Self.makeThumbnail(pngData: png, hash: hash, filesDirectory: filesDirectory)
            }
            return [ClipboardStore.NewRecord(
                type: .image,
                preview: "",
                content: nil,
                filePath: imagePath,
                thumbPath: thumbPath,
                byteSize: png.count,
                searchText: nil,
                hash: hash,
                createdAt: Date()
            )]
        }

        // 3. 文本：≤16KB 内联入库，超长落盘存引用
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let bytes = Data(text.utf8).count
        let hash = ClipboardStore.contentHash("text:", Data(text.utf8))
        var filePath: String?
        if bytes > ClipboardLimits.inlineTextBytes {
            let path = filesDirectory.appendingPathComponent("\(hash).txt").path
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
            filePath = path
        }
        let preview = String(text.prefix(ClipboardLimits.previewChars))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return [ClipboardStore.NewRecord(
            type: .text,
            preview: preview,
            content: filePath == nil ? text : nil,
            filePath: filePath,
            thumbPath: nil,
            byteSize: bytes,
            searchText: text,
            hash: hash,
            createdAt: Date()
        )]
    }

    /// 粘贴板位图数据 → 标准 PNG（TIFF 未压缩转码；PNG 原样返回避免重编码）
    private static func normalizedPNG(from data: Data) -> Data? {
        if let rep = NSBitmapImageRep(data: data) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    /// PNG 像素尺寸（ImageIO 只读头部，不解码位图）
    private static func pngPixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// 大图快速缩略图：ImageIO 直接解码降采样，不展开全尺寸位图
    private static func makeThumbnail(pngData: Data, hash: String, filesDirectory: URL) -> String? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: ClipboardLimits.thumbMaxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let path = filesDirectory.appendingPathComponent("thumb-\(hash).png").path
        try? data.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// 捕获结果入库并更新内存缓存（主线程）
    private func commit(_ records: [ClipboardStore.NewRecord]) {
        for record in records {
            let (id, _) = store.upsert(record)
            let item = ClipboardItem(
                id: id,
                type: record.type,
                preview: record.preview,
                content: record.content,
                filePath: record.filePath,
                thumbPath: record.thumbPath,
                byteSize: record.byteSize,
                useCount: 0,
                createdAt: record.createdAt
            )
            memory.removeAll { $0.item.id == id }
            memory.insert(Self.makeEntry(item), at: 0)
        }
        if memory.count > ClipboardLimits.memoryCapacity {
            memory.removeLast(memory.count - ClipboardLimits.memoryCapacity)
        }
        if let first = records.first {
            NSLog("[OpenMyApp] 剪切板捕获: \(first.type) \(first.byteSize)B, 缓存 \(memory.count) 条")
        }
    }

    // MARK: - 搜索（主线程入口）

    /// 内存缓存搜索：空查询返回最近记录（浏览）；有关键字按空格分词 AND 匹配，
    /// 大小写不敏感，凑满 limit 提前结束（小写检索文本已在缓存装载时预计算）
    func searchMemory(_ query: String, limit: Int) -> [ClipboardItem] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard !tokens.isEmpty else { return memory.prefix(limit).map(\.item) }
        var hits: [ClipboardItem] = []
        for entry in memory {
            guard !entry.searchTextLower.isEmpty else { continue }
            if tokens.allSatisfy({ SearchEngine.bytesContain(entry.searchTextLower, $0) }) {
                hits.append(entry.item)
                if hits.count == limit { break }
            }
        }
        return hits
    }

    /// 数据库搜索（workQueue 执行，结果回主线程）；覆盖内存 200 条之外的历史。
    /// 生成由调用方（LauncherModel）控制，过期回调在 UI 层丢弃
    func searchDatabase(tokens: [String], limit: Int, completion: @escaping ([ClipboardItem]) -> Void) {
        workQueue.async { [store] in
            let items = store.search(tokens: tokens, limit: limit)
            DispatchQueue.main.async { completion(items) }
        }
    }

    // MARK: - 激活：回写剪切板 + 自动粘贴

    /// 选中一条记录：回写系统剪切板（自动粘贴的前半步）并记录使用次数。
    /// 调用方（PanelController）已先隐藏面板。
    func activate(_ item: ClipboardItem) {
        store.recordUse(id: item.id)
        if let index = memory.firstIndex(where: { $0.item.id == item.id }) {
            let old = memory[index].item
            memory[index] = MemoryEntry(
                item: ClipboardItem(
                    id: old.id, type: old.type, preview: old.preview, content: old.content,
                    filePath: old.filePath, thumbPath: old.thumbPath, byteSize: old.byteSize,
                    useCount: old.useCount + 1, createdAt: old.createdAt
                ),
                searchTextLower: memory[index].searchTextLower
            )
        }
        workQueue.async { [weak self] in
            guard let self else { return }
            guard let payload = self.prepareWritePayload(for: item) else { return }
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                switch payload {
                case .text(let string):
                    pasteboard.setString(string, forType: .string)
                case .image(let png, let tiff):
                    pasteboard.setData(png, forType: .png)
                    pasteboard.setData(tiff, forType: .tiff)
                }
                // 自己的回写不要被轮询再捕获
                let count = pasteboard.changeCount
                self.workQueue.async { self.suppressedChangeCount = count }
                self.scheduleAutoPaste()
            }
        }
    }

    private enum WritePayload {
        case text(String)
        case image(png: Data, tiff: Data)
    }

    /// 文件记录回写「路径文本」（产品决策）；大文本从文件读回全文
    private func prepareWritePayload(for item: ClipboardItem) -> WritePayload? {
        switch item.type {
        case .text:
            let string = item.content
                ?? (item.filePath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) })
                ?? item.preview
            return .text(string)
        case .file:
            return .text(item.preview)
        case .image:
            guard let path = item.filePath, let png = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let rep = NSBitmapImageRep(data: png),
                  let tiff = rep.tiffRepresentation else { return nil }
            return .image(png: png, tiff: tiff)
        }
    }

    /// 选中后自动向前台应用模拟 ⌘V（需辅助功能权限；未授权降级为仅复制并引导授权一次）
    private func scheduleAutoPaste() {
        guard AXIsProcessTrusted() else {
            NSLog("[OpenMyApp] 未授权辅助功能，本次仅复制到剪切板")
            if !axPromptShown {
                axPromptShown = true
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            return
        }
        // 面板已隐藏，稍等前台应用恢复按键焦点再注入
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Self.postCommandV()
        }
    }

    private static func postCommandV() {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
    }
}
