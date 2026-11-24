import Foundation
import AppKit
import SwiftUI

// MARK: - 折叠结构计算

/// 一对可折叠的花括号/方括号。
struct JsonFold: Equatable {
    let openLine: Int    // 0-based
    let closeLine: Int   // 0-based
    let level: Int       // 嵌套层级（0 = 根容器）
    var lineCount: Int { closeLine - openLine - 1 }
}

enum JsonFolder {
    /// 扫描全文的花括号/方括号配对（跳过字符串字面量），得到所有可折叠块。
    /// 同一行内闭合的（如 `"a" : { }`、`[1, 2]`）不构成折叠块。
    static func folds(in text: String) -> [JsonFold] {
        var out: [JsonFold] = []
        var stack: [(line: Int, level: Int)] = []
        var lineIdx = 0
        var inString = false
        var escape = false
        for ch in text {
            switch ch {
            case "\n":
                lineIdx += 1
                inString = false
                escape = false
            case "\\":
                if inString { escape = !escape }
            case "\"":
                if !escape { inString.toggle() }
                escape = false
            case "{", "[":
                if !inString { stack.append((lineIdx, stack.count)) }
                escape = false
            case "}", "]":
                escape = false
                if !inString, let top = stack.popLast(), lineIdx > top.line {
                    out.append(JsonFold(openLine: top.line, closeLine: lineIdx, level: top.level))
                }
            default:
                escape = false
            }
        }
        return out.sorted { $0.openLine < $1.openLine }
    }
}

// MARK: - 折叠渲染

struct FoldChevron: Equatable {
    let range: NSRange   // 展示文本里 ▾/▸ 的位置（UTF-16）
    let openLine: Int
}

struct FoldRender: Equatable {
    let text: String
    let chevrons: [FoldChevron]
}

enum JsonFoldRenderer {
    static let expandMark = "▾"
    static let collapseMark = "▸"

    /// 按折叠状态重排文本：折叠块压成 `opener ⋯ N 行 closer` 一行，
    /// 可折叠行首加 ▾/▸ 标记。collapsed 里的 openLine 即使嵌套祖先已折叠也无害（整块被跳过）。
    static func render(_ pretty: String, folds: [JsonFold], collapsed: Set<Int>) -> FoldRender {
        let lines = pretty.components(separatedBy: "\n")
        let foldByOpen = Dictionary(folds.map { ($0.openLine, $0) }, uniquingKeysWith: { a, _ in a })

        var out = ""
        var outUTF16 = 0
        var chevrons: [FoldChevron] = []

        func append(_ s: String) {
            out += s
            outUTF16 += (s as NSString).length
        }

        var i = 0
        while i < lines.count {
            if i > 0 { append("\n") }
            if let f = foldByOpen[i], collapsed.contains(f.openLine) {
                let opener = lines[i].trimmingCharacters(in: .whitespaces)
                let closer = lines[f.closeLine].trimmingCharacters(in: .whitespaces)
                chevrons.append(FoldChevron(
                    range: NSRange(location: outUTF16, length: (collapseMark as NSString).length),
                    openLine: f.openLine))
                append(collapseMark + " " + opener + " ⋯ \(f.lineCount) 行 " + closer)
                i = f.closeLine + 1
            } else {
                if let f = foldByOpen[i] {
                    chevrons.append(FoldChevron(
                        range: NSRange(location: outUTF16, length: (expandMark as NSString).length),
                        openLine: f.openLine))
                    append(expandMark + " ")
                }
                append(lines[i])
                i += 1
            }
        }
        return FoldRender(text: out, chevrons: chevrons)
    }
}

// MARK: - 可点击折叠的文本视图

/// NSTextView 子类：点击 ▾/▸ 切换折叠；其余点击走系统默认（选中文本）。
final class FoldClickTextView: NSTextView {
    var chevrons: [FoldChevron] = []
    var onToggleFold: ((Int) -> Void)?

    /// NSTextView.characterIndex(for:) 在部分布局状态下会错误地返回文末索引，
    /// 这里改用 layoutManager 的两步映射（view 点 → 容器点 → glyph → character）。
    override func mouseDown(with event: NSEvent) {
        if onToggleFold != nil, !chevrons.isEmpty,
           let lm = layoutManager, let tc = textContainer {
            let pView = convert(event.locationInWindow, from: nil)
            let pContainer = NSPoint(x: pView.x - textContainerOrigin.x,
                                     y: pView.y - textContainerOrigin.y)
            var frac: CGFloat = 0
            let glyph = lm.glyphIndex(for: pContainer, in: tc,
                                      fractionOfDistanceThroughGlyph: &frac)
            if glyph < lm.numberOfGlyphs {
                let idx = lm.characterIndexForGlyph(at: glyph)
                // 标记前后各容差 1 字符，便于点中
                for c in chevrons where idx >= c.range.location - 1 && idx <= NSMaxRange(c.range) {
                    onToggleFold?(c.openLine)
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }
}

struct FoldableJsonTextView: NSViewRepresentable {
    let pretty: String
    var collapsed: Set<Int>
    var onToggle: (Int) -> Void
    var highlight: String
    var matchIndex: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastSignature = ""
        /// folds(in:) 只取决于 pretty：同一份文本不重复扫描（逐字符扫描，大记录要几十毫秒）
        var foldsSource: String?
        var folds: [JsonFold] = []
        /// 最近一次算出的实际折叠集合；pretty / 折叠状态 / 搜索词都没变时直接沿用
        var effectiveKey = ""
        var effective: Set<Int> = []
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = FoldClickTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        ]

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? FoldClickTextView else { return }
        let co = context.coordinator

        if co.foldsSource != pretty {
            co.foldsSource = pretty
            co.folds = JsonFolder.folds(in: pretty)
        }
        // 展示文本由「文本、折叠状态、搜索词」决定：三者都没变（例如只是切换到下一个匹配）就不重算
        let key = "\(pretty.utf8.count)|\(pretty.hashValue)|\(collapsed.hashValue)|\(highlight)"
        if key != co.effectiveKey {
            co.effectiveKey = key
            // 搜索时：含匹配的折叠块自动展开，保证匹配数/跳转与可见文本一致
            co.effective = Self.effectiveCollapsed(collapsed, folds: co.folds,
                                                    pretty: pretty, needle: highlight)
        }
        tv.onToggleFold = onToggle
        let sig = key + "|\(matchIndex)"
        guard sig != co.lastSignature else { return }
        co.lastSignature = sig

        let render = JsonFoldRenderer.render(pretty, folds: co.folds, collapsed: co.effective)
        let m = NSMutableAttributedString(attributedString: JsonHighlighter.attributed(render.text))
        let active = HighlightedTextView.applySearchHighlights(m, needle: highlight, matchIndex: matchIndex)

        tv.textStorage?.setAttributedString(m)
        tv.chevrons = render.chevrons
        if let active {
            tv.scrollRangeToVisible(active)
        }
    }

    /// 折叠集合去掉"包含搜索匹配的块"（按字符区间相交判断）。
    static func effectiveCollapsed(_ collapsed: Set<Int>, folds: [JsonFold],
                                   pretty: String, needle: String) -> Set<Int> {
        guard !collapsed.isEmpty, !needle.isEmpty else { return collapsed }
        let matches = HighlightedTextView.matchRanges(in: pretty, needle: needle)
        guard !matches.isEmpty else { return collapsed }
        let lines = pretty.components(separatedBy: "\n")
        var lineStarts: [Int] = []
        var acc = 0
        for l in lines {
            lineStarts.append(acc)
            acc += (l as NSString).length + 1
        }
        var result = collapsed
        for f in folds where result.contains(f.openLine) {
            guard f.closeLine < lineStarts.count else { continue }
            let blockStart = lineStarts[f.openLine]
            let blockEnd = lineStarts[f.closeLine] + (lines[f.closeLine] as NSString).length
            let block = NSRange(location: blockStart, length: blockEnd - blockStart)
            if matches.contains(where: { NSIntersectionRange($0, block).length > 0 }) {
                result.remove(f.openLine)
            }
        }
        return result
    }
}
