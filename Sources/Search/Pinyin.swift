import Foundation

/// 中文 → 拼音转换（基于 CFStringTransform，无第三方依赖），带缓存
enum Pinyin {
    struct Info {
        /// 全拼，如 "fangda"
        let full: String
        /// 拼音首字母，如 "fd"
        let initials: String
    }

    private static let cache = NSCache<NSString, Box>()

    /// 装箱以便放入 NSCache
    private final class Box {
        let info: Info
        init(_ info: Info) { self.info = info }
    }

    /// 不含汉字时返回 nil
    static func info(for text: String) -> Info? {
        if let hit = cache.object(forKey: text as NSString) { return hit.info }
        guard text.contains(where: { $0.isHanCharacter }) else { return nil }

        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)

        // "访达" → "fǎng dá" → ["fang", "da"]
        let syllables = (mutable as String)
            .lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !syllables.isEmpty else { return nil }

        let info = Info(
            full: syllables.joined(),
            initials: syllables.compactMap { $0.first.map(String.init) }.joined()
        )
        cache.setObject(Box(info), forKey: text as NSString)
        return info
    }
}

private extension Character {
    /// 是否为常用 CJK 统一表意文字
    var isHanCharacter: Bool {
        guard unicodeScalars.count == 1, let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x20000...0x2A6DF:
            return true
        default:
            return false
        }
    }
}
