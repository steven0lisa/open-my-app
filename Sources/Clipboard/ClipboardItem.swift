import Foundation

/// 一条剪切板历史记录
/// 只有 ≤16KB 的文本会把全文放在 content / DB 列里；图片与大文本只存文件引用
struct ClipboardItem: Identifiable, Equatable {
    enum ItemType: Int {
        case text = 0
        case image = 1
        case file = 2
    }

    let id: Int64
    let type: ItemType
    /// 文本：前 200 字符（换行折叠为空格）；文件：完整路径；图片：空
    let preview: String
    /// 小文本（≤16KB）的全文；大文本为 nil（全文在 filePath 指向的文件里）
    let content: String?
    /// 大文本 / 图片的落盘文件；文件类型 = 被复制的原始路径
    let filePath: String?
    /// 图片缩略图（列表展示用，原图在 filePath）
    let thumbPath: String?
    let byteSize: Int
    let useCount: Int
    let createdAt: Date

    /// 列表首行展示（图片类型需要本地化 + 大小格式化，由 UI 层组装）
    var titleLine: String {
        switch type {
        case .text:
            return preview
                .components(separatedBy: .newlines)
                .first?
                .trimmingCharacters(in: .whitespaces) ?? ""
        case .file:
            return (preview as NSString).lastPathComponent
        case .image:
            return ""
        }
    }

    var searchTextLower: String {
        switch type {
        case .text: return (content ?? preview).lowercased()
        case .file: return preview.lowercased()
        case .image: return ""
        }
    }
}

/// 剪切板功能的数值约定（集中一处，避免魔法数散落）
enum ClipboardLimits {
    /// 超过该字节数的文本不入 DB 列，落盘存文件
    static let inlineTextBytes = 16 * 1024
    /// 超过该字节数的图片生成缩略图；另见 thumbMaxPixel 的双阈值（像素尺寸超 2 倍也生成）
    static let imageThumbBytes = 512 * 1024
    /// 缩略图最长边像素
    static let thumbMaxPixel = 440
    /// 内存缓存条数上限，超出走数据库
    static let memoryCapacity = 200
    /// 预览字段长度
    static let previewChars = 200
    /// 一次复制事件最多记录的文件数（Finder 多选复制）
    static let maxFilesPerCapture = 20
    /// 剪切板模式无搜索词时展示的最近条数（浏览一屏）
    static let browseCount = 9
}
