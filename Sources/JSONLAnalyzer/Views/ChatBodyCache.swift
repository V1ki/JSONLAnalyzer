import SwiftUI
import AppKit

/// 折叠时显示的一块内容：一段富文本，或一张表格的一部分行
enum ChatBodyPiece {
    case text(NSAttributedString)
    case table(rows: [[String]])
}

/// 一条正文按 Markdown 渲染的结果。
///
/// 正文先切成片段：表格要画成真正的列（单元格各自换行），富文本画不出来，
/// 所以单独成一段交给视图用 Grid 显示；其余片段交给 Markdown 渲染器。
final class ChatBodyRendered {
    /// 按显示方式切好的片段，顺序与正文中一致
    let segments: [ConversationBuilder.BodySegment]
    /// Markdown 片段渲染好的富文本（片段下标 → 富文本）
    let texts: [Int: NSAttributedString]
    /// 折叠时最多显示的行数
    static let clippedLines = 12

    /// 没有表格时的整段富文本（各片段首尾相接）；有表格时为 nil，按片段逐个显示
    let whole: NSAttributedString?

    /// 折叠时显示的部分：从正文开头起按片段取，直到用完行数预算。
    /// 长正文的默认状态；表格不会整张藏起来，说明文字之后接着露出表头和前几行
    let folded: [ChatBodyPiece]

    /// 正文比折叠后显示的多，需要「展开」
    let isLong: Bool

    init(body: String) {
        segments = ConversationBuilder.splitTables(body)
        var texts: [Int: NSAttributedString] = [:]
        for (i, seg) in segments.enumerated() {
            if case .markdown(let src) = seg { texts[i] = MarkdownRenderer.render(src) }
        }
        self.texts = texts

        if segments.contains(where: { if case .table = $0 { return true }; return false }) {
            whole = nil
            let (pieces, hidden) = Self.fold(segments, texts: texts)
            folded = pieces
            isLong = hidden
        } else {
            let joined = NSMutableAttributedString()
            for (i, _) in segments.enumerated() {
                if i > 0 { joined.append(NSAttributedString(string: "\n")) }
                if let t = texts[i] { joined.append(t) }
            }
            let cut = ConversationBuilder.clipping(joined, toLines: Self.clippedLines)
            whole = joined
            // clipping 在够短时原样返回同一个对象
            isLong = cut !== joined
            folded = [.text(isLong ? cut : joined)]
        }
    }

    /// 展开时显示的第 index 个片段
    func piece(_ seg: ConversationBuilder.BodySegment, index: Int) -> ChatBodyPiece {
        switch seg {
        case .markdown: return .text(texts[index] ?? NSAttributedString())
        case .table(let rows): return .table(rows: rows)
        }
    }

    /// 从正文开头起逐个片段取内容，直到用完行数预算；有内容没放下的记为 hidden
    private static func fold(_ segments: [ConversationBuilder.BodySegment],
                             texts: [Int: NSAttributedString]) -> (pieces: [ChatBodyPiece], hidden: Bool) {
        var pieces: [ChatBodyPiece] = []
        var remaining = clippedLines
        for (i, seg) in segments.enumerated() {
            guard remaining > 0 else { return (pieces, true) }
            switch seg {
            case .markdown:
                guard let t = texts[i] else { continue }
                let lines = visibleLines(t.string)
                if lines > remaining {
                    pieces.append(.text(ConversationBuilder.clipping(t, toLines: remaining)))
                    return (pieces, true)
                }
                pieces.append(.text(t))
                remaining -= lines
            case .table(let rows):
                // 单元格长了会折行，这样的行按两行计
                var cost = 0, shown = 0
                for row in rows {
                    cost += row.contains { $0.count > 24 } ? 2 : 1
                    if cost > remaining { break }
                    shown += 1
                }
                pieces.append(.table(rows: Array(rows.prefix(shown))))
                if shown < rows.count { return (pieces, true) }
                remaining -= cost
            }
        }
        return (pieces, false)
    }

    /// 富文本显示出来的行数（空行也算一行；末尾的换行只是最后一行的终止符）
    private static func visibleLines(_ s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        return s.filter { $0 == "\n" }.count + (s.hasSuffix("\n") ? 0 : 1)
    }
}

/// 会话气泡正文的 Markdown 渲染缓存。
///
/// 项目的 Markdown 渲染器是同步的，长报告一次要几十到上百毫秒，不能放在视图的 body 里。
/// 所以按正文缓存：短的正文中同步算完；长的先返回 nil、放到后台算，算好后存进来，
/// 再通知气泡重新取一次（气泡用 @ObservedObject 观察这里）。
///
/// 键是正文本身，不是条目 id：条目 id 每次重建都从头编号，切换文件或筛选之后，
/// 同一个 id 对应的已经是别的内容，按 id 存会把上一份的渲染结果显示出来。
@MainActor
final class ChatBodyCache: ObservableObject {
    /// 超过这个字节数的正文放到后台渲染
    static let asyncThreshold = 2_000
    /// 最多保留的正文条数与字节总量（渲染结果比原文大不少）
    private static let maxEntries = 120
    private static let maxBytes = 2_000_000

    private var entries: [String: ChatBodyRendered] = [:]
    /// 存入的先后顺序，超出上限时淘汰最早的
    private var order: [String] = []
    private var totalBytes = 0
    /// 正在后台渲染的正文
    private var inFlight: Set<String> = []
    /// 右键菜单里手动指定的显示方式（正文 → 是否按 Markdown 渲染）
    private var overrides: [String: Bool] = [:]
    /// 按内容判断的结果（正文 → 类型 → 是否渲染）。判断要把正文扫一遍，而气泡每次重绘都会来问
    private var decisions: [String: [ChatKind: Bool]] = [:]
    private static let maxDecisions = 4_000

    /// 这一条是否按 Markdown 渲染：先看手动指定，再按内容判断
    func renders(_ entry: ChatEntry) -> Bool {
        if let forced = overrides[entry.body] { return forced }
        if let decided = decisions[entry.body]?[entry.kind] { return decided }
        let decided = ConversationBuilder.rendersMarkdown(kind: entry.kind, body: entry.body)
        if decisions.count > Self.maxDecisions { decisions.removeAll(keepingCapacity: true) }
        decisions[entry.body, default: [:]][entry.kind] = decided
        return decided
    }

    /// 手动指定一条正文是否按 Markdown 渲染
    func setRenders(_ renders: Bool, for body: String) {
        objectWillChange.send()
        overrides[body] = renders
    }

    /// 已有的渲染结果；没算过且正文不长时同步算出来。长正文放后台渲染，先返回 nil
    func rendered(_ body: String) -> ChatBodyRendered? {
        if let r = entries[body] { return r }
        guard body.utf8.count <= Self.asyncThreshold else {
            renderInBackground(body)
            return nil
        }
        let r = ChatBodyRendered(body: body)
        remember(r, body: body)
        return r
    }

    private func renderInBackground(_ body: String) {
        guard !inFlight.contains(body) else { return }
        inFlight.insert(body)
        Task.detached(priority: .userInitiated) {
            let rendered = ChatBodyRendered(body: body)
            await self.store(rendered, body: body)
        }
    }

    private func store(_ rendered: ChatBodyRendered, body: String) {
        inFlight.remove(body)
        objectWillChange.send()
        remember(rendered, body: body)
    }

    private func remember(_ rendered: ChatBodyRendered, body: String) {
        guard entries[body] == nil else { return }
        entries[body] = rendered
        order.append(body)
        totalBytes += body.utf8.count
        while order.count > Self.maxEntries || totalBytes > Self.maxBytes {
            let old = order.removeFirst()
            totalBytes -= old.utf8.count
            entries[old] = nil
        }
    }
}

/// 按 Markdown 渲染的一条气泡正文：文字片段用 SwiftUI 的 Text 显示富文本，表格用 Grid 画成列。
struct MarkdownBody: View {
    let rendered: ChatBodyRendered
    let expanded: Bool

    var body: some View {
        if expanded, let whole = rendered.whole {
            // 没有表格：一整块富文本
            Text(AttributedString(whole)).textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                let pieces: [ChatBodyPiece] = expanded
                    ? rendered.segments.enumerated().map { rendered.piece($1, index: $0) }
                    : rendered.folded
                ForEach(pieces.indices, id: \.self) { i in
                    if case .text(let t) = pieces[i] {
                        Text(AttributedString(t)).textSelection(.enabled)
                    } else if case .table(let rows) = pieces[i] {
                        MarkdownTableView(rows: rows)
                    }
                }
            }
        }
    }
}

/// Markdown 表格：表头加粗，下面一条分隔线，单元格各自换行，所以再宽也不会散。
struct MarkdownTableView: View {
    let rows: [[String]]
    private let head: [String]
    private let body_: [[String]]

    init(rows: [[String]]) {
        self.rows = rows
        head = rows.first ?? []
        body_ = Array(rows.dropFirst())
    }

    private var columns: Int { max(head.count, body_.map(\.count).max() ?? 0) }

    /// 单元格里的行内 Markdown（`代码`、**加粗**）照常渲染；全列等宽的代码名用等宽字体
    private func cell(_ text: String) -> Text {
        Text(AttributedString(MarkdownRenderer.renderInline(text)))
    }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 5) {
            GridRow {
                ForEach(0..<columns, id: \.self) { c in
                    cell(c < head.count ? head[c] : "").fontWeight(.semibold)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(body_.indices, id: \.self) { r in
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        cell(c < body_[r].count ? body_[r][c] : "")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.system(size: MarkdownRenderer.bodySize - 1))
        .padding(.vertical, 2)
        .fixedSize(horizontal: false, vertical: true)
    }
}
