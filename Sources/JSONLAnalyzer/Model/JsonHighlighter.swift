import Foundation
import AppKit
import SwiftUI

/// JSON 语法着色（适配浅色/深色外观由系统语义色自动完成）。
enum JsonHighlighter {
    static func attributed(_ json: String, fontSize: CGFloat = 12) -> NSAttributedString {
        let base = NSMutableAttributedString(string: json, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
        guard !json.isEmpty else { return base }

        let key = NSColor.systemPurple
        let string = NSColor.systemRed
        let number = NSColor.systemBlue
        let boolNull = NSColor.systemOrange

        let patterns: [(NSRegularExpression, NSColor)] = [
            (try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"(?=\s*:)"#), key),
            (try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#), string),
            (try! NSRegularExpression(pattern: #"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#), number),
            (try! NSRegularExpression(pattern: #"\b(?:true|false|null)\b"#), boolNull),
        ]
        let full = NSRange(json.startIndex..<json.endIndex, in: json)
        for (re, color) in patterns {
            re.enumerateMatches(in: json, range: full) { m, _, _ in
                guard let m else { return }
                base.addAttribute(.foregroundColor, value: color, range: m.range)
            }
        }
        return base
    }
}

/// 只读、可滚动、可选择的文本视图，支持搜索高亮与跳转到当前匹配。
struct HighlightedTextView: NSViewRepresentable {
    let attributed: NSAttributedString
    /// 搜索词（空 = 不高亮）
    var highlight: String = ""
    /// 当前第几个匹配（0-based），滚动定位并用更亮的底色
    var matchIndex: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastSignature = ""
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
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
        guard let tv = scroll.documentView as? NSTextView else { return }
        // 内容或搜索状态变化时才重建，保留用户在视图内的选择
        let sig = "\(attributed.length)|\(attributed.string.hashValue)|\(highlight)|\(matchIndex)"
        guard sig != context.coordinator.lastSignature else { return }
        context.coordinator.lastSignature = sig

        let m = NSMutableAttributedString(attributedString: attributed)
        let active = Self.applySearchHighlights(m, needle: highlight, matchIndex: matchIndex)
        tv.textStorage?.setAttributedString(m)
        if let active {
            tv.scrollRangeToVisible(active)
        }
    }

    /// 在 base 上应用搜索高亮（当前匹配亮黄、其余浅黄），返回应滚动定位的范围。
    static func applySearchHighlights(_ m: NSMutableAttributedString,
                                      needle: String, matchIndex: Int) -> NSRange? {
        let ranges = matchRanges(in: m.string, needle: needle)
        guard !ranges.isEmpty else { return nil }
        let activeIdx = min(max(matchIndex, 0), ranges.count - 1)
        for (i, r) in ranges.enumerated() {
            m.addAttribute(.backgroundColor,
                           value: i == activeIdx ? NSColor.systemYellow
                                                 : NSColor.systemYellow.withAlphaComponent(0.38),
                           range: r)
        }
        return ranges[activeIdx]
    }

    /// 大小写不敏感的全部匹配位置（供视图计算匹配数，与高亮逻辑共用一份实现）。
    static func matchRanges(in s: String, needle: String) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        let ns = s as NSString
        var out: [NSRange] = []
        var loc = 0
        while loc <= ns.length {
            let r = ns.range(of: needle,
                             options: [.caseInsensitive, .diacriticInsensitive],
                             range: NSRange(location: loc, length: ns.length - loc))
            guard r.location != NSNotFound, r.length > 0 else { break }
            out.append(r)
            loc = r.location + r.length
        }
        return out
    }
}
