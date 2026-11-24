import Foundation

/// 从一条 JSON 记录里抽取"适合按 Markdown 阅读"的长文本字段。
struct TextCandidate: Identifiable, Hashable {
    let path: String
    let text: String
    var id: String { path }
    var length: Int { text.count }
}

enum TextExtractor {
    /// 视为文本的最低长度（无换行、叶子名也不含暗示时的兜底阈值）
    static let minPlainLength = 60
    /// 叶子名暗示为正文的最低长度
    static let minLeafHintLength = 8
    /// 常见正文叶子名（小写比较，兼容复数形式）
    static let leafHints: Set<String> = [
        "text", "content", "message", "body", "markdown",
        "prompt", "completion", "answer", "output", "reasoning",
    ]

    static func isCandidate(leafKey: String, value: String) -> Bool {
        guard !isBlank(value) else { return false }
        if value.contains("\n") { return true }
        let n = value.count
        if n >= minPlainLength { return true }
        var leaf = leafKey.lowercased()
        if leaf.hasSuffix("s") { leaf.removeLast() }
        if leafHints.contains(leaf) { return n >= minLeafHintLength }
        return false
    }

    /// 数组里的字符串元素（如流式逐词分块 texts: ["你好","呀",…]）大多是碎片，
    /// 只保留足够长的整段文本，避免候选列表被几百个词淹没。
    static func isArrayElementCandidate(value: String) -> Bool {
        !isBlank(value) && value.count >= minPlainLength
    }

    private static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 递归抽取。数组元素路径带下标（content[0].text），便于区分同一行里的多段文本。
    /// 返回按长度降序：默认选中的第一条通常就是正文。
    static func extract(root: Any, limit: Int = 200) -> [TextCandidate] {
        var out: [TextCandidate] = []
        walk(root, path: "", leaf: "", depth: 0, out: &out, limit: limit)
        return out.sorted { $0.length != $1.length ? $0.length > $1.length : $0.path < $1.path }
    }

    private static func walk(_ v: Any, path: String, leaf: String, depth: Int,
                             out: inout [TextCandidate], limit: Int) {
        guard depth <= 12, out.count < limit else { return }
        if let dict = v as? [String: Any] {
            for (k, sub) in dict {
                let p = path.isEmpty ? k : path + "." + k
                if let s = sub as? String {
                    if isCandidate(leafKey: k, value: s) {
                        out.append(TextCandidate(path: p, text: s))
                    }
                } else {
                    walk(sub, path: p, leaf: k, depth: depth + 1, out: &out, limit: limit)
                }
            }
        } else if let arr = v as? [Any] {
            for (i, el) in arr.enumerated() {
                let p = "\(path)[\(i)]"
                if let s = el as? String {
                    if isArrayElementCandidate(value: s) {
                        out.append(TextCandidate(path: p, text: s))
                    }
                } else {
                    walk(el, path: p, leaf: leaf, depth: depth + 1, out: &out, limit: limit)
                }
            }
        }
    }
}
