import Foundation
import AppKit

/// 轻量 Markdown 块级渲染器。
///
/// 为什么不用 `NSAttributedString(markdown:)` 直接渲染：Foundation 的解析结果只带
/// presentationIntent 结构标签，字体全部为空、块间换行符被剥掉，放进 NSTextView
/// 会糊成一片。这里按行切块（标题/列表/代码块/引用/水平线/段落），
/// 每块的行内格式（粗体、斜体、行内代码、链接）再用 Foundation 的行内解析处理，
/// 最后自己套字体、缩进、配色——得到的是自包含的 NSAttributedString，
/// 可以直接用于搜索高亮。
enum MarkdownRenderer {

    static let bodySize: CGFloat = 13
    static let headingSizes: [CGFloat] = [24, 19, 16.5, 15, 14, 13.5]
    static let bulletMarkers = ["•", "◦", "▪"]

    static func render(_ source: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var i = 0
        var firstBlock = true

        func paragraphSpacing() {
            if !firstBlock { out.appendString("\n") }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 空行
            if trimmed.isEmpty { i += 1; continue }

            // 代码围栏
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                i += 1
                var code: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }   // 跳过闭合围栏
                paragraphSpacing()
                appendCodeBlock(code.joined(separator: "\n"), language: lang, to: out)
                out.appendString("\n")
                firstBlock = false
                continue
            }

            // 标题
            if let level = headingLevel(trimmed) {
                i += 1
                paragraphSpacing()
                appendHeading(String(trimmed.drop { $0 == "#" }.drop { $0 == " " }),
                              level: level, to: out)
                out.appendString("\n")
                firstBlock = false
                continue
            }

            // 水平线
            if isHorizontalRule(trimmed) {
                i += 1
                paragraphSpacing()
                appendHR(to: out)
                firstBlock = false
                continue
            }

            // 引用块（连续 > 行合并）
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quote.append(String(t.dropFirst().drop { $0 == " " }))
                    i += 1
                }
                paragraphSpacing()
                appendQuote(quote.joined(separator: "\n"), to: out)
                out.appendString("\n")
                firstBlock = false
                continue
            }

            // 列表项（连续项合并；缩进决定层级）
            if listItem(line) != nil {
                paragraphSpacing()
                var prevLevel = -1
                while i < lines.count, let it = listItem(lines[i]) {
                    appendListItem(it, to: out)
                    prevLevel = it.level
                    i += 1
                    if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        // 列表后的空行：若下一行还是列表项则视为松散列表，继续
                        if let next = listItem(lines[min(i + 1, lines.count - 1)]), next.level == prevLevel {
                            out.appendString("\n")
                            i += 1
                        } else { break }
                    }
                }
                out.appendString("\n")
                firstBlock = false
                continue
            }

            // 段落：连续普通行
            var para: [String] = [line]
            i += 1
            while i < lines.count {
                let t = lines[i]
                let tt = t.trimmingCharacters(in: .whitespaces)
                if tt.isEmpty || headingLevel(tt) != nil || isHorizontalRule(tt)
                    || tt.hasPrefix(">") || tt.hasPrefix("```") || tt.hasPrefix("~~~")
                    || listItem(t) != nil { break }
                para.append(t)
                i += 1
            }
            paragraphSpacing()
            appendParagraph(para.joined(separator: "\n"), to: out)
            out.appendString("\n")
            firstBlock = false
        }
        return out
    }

    // MARK: - 块识别

    private static func headingLevel(_ line: String) -> Int? {
        var n = 0
        for ch in line {
            if ch == "#" { n += 1 } else { break }
        }
        guard n >= 1, n <= 6 else { return nil }
        let after = line.dropFirst(n)
        guard after.first == " " || after.first == "\t" else { return nil }
        return n
    }

    private static func isHorizontalRule(_ s: String) -> Bool {
        let set: Set<Character> = ["-", "*", "_"]
        guard s.count >= 3 else { return false }
        let chars = Array(s)
        guard set.contains(chars[0]) else { return false }
        var count = 0
        for c in chars {
            if c == " " || c == "\t" { continue }
            guard c == chars[0] else { return false }
            count += 1
        }
        return count >= 3
    }

    struct ListItem {
        let level: Int      // 0-based 缩进层级
        let ordered: Bool
        let marker: String  // "•" 或 "1."
        let content: String
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.drop { $0 == " " }
        // 无序：- * +
        if let first = rest.first, ["-", "*", "+"].contains(first) {
            let after = rest.dropFirst()
            guard after.first == " " || after.first == "\t" else { return nil }
            let content = String(after).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return nil }
            return ListItem(level: min(indent / 2, bulletMarkers.count - 1),
                            ordered: false, marker: bulletMarkers[min(indent / 2, bulletMarkers.count - 1)],
                            content: content)
        }
        // 有序：1. 2) …
        var digits = ""
        var iter = rest.makeIterator()
        while let c = iter.next(), c.isNumber { digits.append(c) }
        let afterDigits = rest.dropFirst(digits.count)
        if !digits.isEmpty, digits.count <= 3,
           afterDigits.first == "." || afterDigits.first == ")" {
            let after = afterDigits.dropFirst()
            guard after.first == " " || after.first == "\t" else { return nil }
            let content = String(after).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return nil }
            return ListItem(level: min(indent / 2, bulletMarkers.count - 1),
                            ordered: true, marker: "\(digits).",
                            content: content)
        }
        return nil
    }

    // MARK: - 块输出

    private static func appendHeading(_ text: String, level: Int, to out: NSMutableAttributedString) {
        let size = headingSizes[min(level, headingSizes.count) - 1]
        let inline = renderInline(text)
        inline.addAttribute(.font,
                            value: NSFont.systemFont(ofSize: size, weight: .bold),
                            range: NSRange(location: 0, length: inline.length))
        out.append(inline)
    }

    private static func appendParagraph(_ text: String, to out: NSMutableAttributedString) {
        out.append(renderInline(text))
    }

    private static func appendQuote(_ text: String, to out: NSMutableAttributedString) {
        let inline = renderInline(text)
        let full = NSRange(location: 0, length: inline.length)
        inline.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: full)
        let indent = NSMutableParagraphStyle()
        indent.headIndent = 14
        indent.firstLineHeadIndent = 14
        inline.addAttribute(.paragraphStyle, value: indent, range: full)
        out.append(NSAttributedString(string: "▎ ",
                                      attributes: [.foregroundColor: NSColor.tertiaryLabelColor]))
        out.append(inline)
    }

    private static func appendCodeBlock(_ code: String, language: String, to out: NSMutableAttributedString) {
        var text = code
        if !language.isEmpty {
            let langAttr = NSAttributedString(string: language + "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            out.append(langAttr)
        }
        if text.hasSuffix("\n") { text.removeLast() }
        let block = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
        let full = NSRange(location: 0, length: block.length)
        block.addAttribute(.backgroundColor,
                           value: NSColor.controlBackgroundColor, range: full)
        let inset = NSMutableParagraphStyle()
        inset.headIndent = 8
        inset.firstLineHeadIndent = 8
        inset.tailIndent = -8
        block.addAttribute(.paragraphStyle, value: inset, range: full)
        out.append(block)
    }

    private static func appendHR(to out: NSMutableAttributedString) {
        out.append(NSAttributedString(string: "──────────", attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
    }

    private static func appendListItem(_ item: ListItem, to out: NSMutableAttributedString) {
        let marker = item.marker
        let pad = String(repeating: "    ", count: item.level)
        out.append(NSAttributedString(string: pad + marker + "  ", attributes: [
            .font: NSFont.systemFont(ofSize: bodySize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        let inline = renderInline(item.content)
        let ps = NSMutableParagraphStyle()
        ps.headIndent = CGFloat(pad.count + marker.count + 2)
        ps.firstLineHeadIndent = 0
        inline.addAttribute(.paragraphStyle, value: ps,
                            range: NSRange(location: 0, length: inline.length))
        out.append(inline)
        out.appendString("\n")
    }

    // MARK: - 行内渲染

    /// 行内 Markdown（粗体/斜体/行内代码/链接/删除线）交给 Foundation，
    /// 但字体要自己按 inlinePresentationIntent 套。
    static func renderInline(_ s: String) -> NSMutableAttributedString {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let out = NSMutableAttributedString()
        guard !s.isEmpty else { return out }
        guard let attr = try? AttributedString(markdown: s, options: opts) else {
            out.append(NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: bodySize),
                .foregroundColor: NSColor.labelColor,
            ]))
            return out
        }
        for run in attr.runs {
            let text = String(attr[run.range].characters)
            guard !text.isEmpty else { continue }
            var font = NSFont.systemFont(ofSize: bodySize)
            var background: NSColor? = nil
            var color = NSColor.labelColor
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.code) {
                    font = .monospacedSystemFont(ofSize: bodySize - 1, weight: .regular)
                    background = .controlBackgroundColor
                }
                if inline.contains(.stronglyEmphasized) {
                    font = font.withBoldTrait
                }
                if inline.contains(.emphasized) {
                    font = font.withItalicTrait
                }
            }
            if run.link != nil { color = .linkColor }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            if let background { attrs[.backgroundColor] = background }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }
}

private extension NSFont {
    var withBoldTrait: NSFont {
        let m = NSFontManager.shared
        let bold = m.convert(self, toHaveTrait: .boldFontMask)
        return bold
    }
    var withItalicTrait: NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
    }
}

private extension NSMutableAttributedString {
    func appendString(_ s: String, attributes: [NSAttributedString.Key: Any] = [:]) {
        append(NSAttributedString(string: s, attributes: attributes))
    }
}
