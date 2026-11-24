import SwiftUI
import AppKit

/// 记录详情的"文本"标签页：把选中的行里抽出的长文本字段按 Markdown 渲染，
/// 支持字面 \n 转真实换行、渲染模式回退与搜索高亮。
struct TextTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var records: RecordStore
    @State private var selectedPath: String?
    @State private var searchText = ""
    @State private var matchIndex = 0
    @State private var cache = TextTabCache()
    /// 后台读取 / 渲染完成时递增，让界面重新读缓存
    @State private var version = 0

    /// 当前选中的字段；行太大、还没在后台读出来时为 nil。
    /// 普通行、普通长度的文本在这里同步算完并缓存，所以选中它们不会出现进度条。
    private var selection: (row: RecordRow, cand: TextCandidate)? {
        guard let row = model.selectedRow,
              let list = cache.candidates(for: row, file: records.file),
              let cand = list.first(where: { $0.path == selectedPath }) ?? list.first else { return nil }
        return (row, cand)
    }

    var body: some View {
        let _ = version
        Group {
            if let row = model.selectedRow {
                let _ = cache.sync(token: records.loadGeneration)
                let list = cache.candidates(for: row, file: records.file)
                let cand = list?.first(where: { $0.path == selectedPath }) ?? list?.first
                if let cand {
                    VStack(spacing: 0) {
                        bar(cand, all: list ?? [], row: row)
                        Divider()
                        if let r = cache.rendered(cand, for: row) {
                            ContentView(rendered: r.attributed, mode: r.mode, converted: r.converted,
                                        truncated: r.truncated,
                                        searchText: $searchText, matchIndex: $matchIndex)
                                .id(row.id)
                        } else {
                            // 长文本在后台渲染
                            ProgressView("渲染中…").frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } else if list == nil {
                    // 大行在后台读取
                    ProgressView("读取第 \(row.id) 行…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyState("该行没有可展示的文本字段",
                               "抽取规则：对象字段含换行、长度 ≥ 60，或字段名为 text/content/message 等且长度 ≥ 8；数组内字符串元素需 ≥ 60")
                }
            } else {
                emptyState("未选择记录", "在中间列表选择一行后，这里会把其中的长文本字段按 Markdown 渲染")
            }
        }
        .task(id: model.selectedRow?.id) {
            // 大行：后台读取文本字段（小行已在 body 里同步读过）
            let generation = records.loadGeneration
            guard let row = model.selectedRow, let file = records.file,
                  cache.candidates(for: row, file: file) == nil else { return }
            let list = await Task.detached(priority: .userInitiated) {
                TextRender.loadCandidates(row, file)
            }.value
            // 期间换了行，或者换了文件（新文件里同样的行号是另一条记录）：结果作废
            guard !Task.isCancelled, records.loadGeneration == generation,
                  model.selectedRow?.id == row.id else { return }
            cache.setCandidates(list, for: row.id)
            version += 1
        }
        .task(id: selection.map { "\($0.row.id)|\($0.cand.path)" }) {
            // 长文本：后台渲染（短文本已在 body 里同步渲染）
            let generation = records.loadGeneration
            guard let sel = selection, cache.rendered(sel.cand, for: sel.row) == nil else { return }
            let cand = sel.cand
            let limit = TextTabCache.renderLimit
            let prepared = await Task.detached(priority: .userInitiated) {
                TextRender.prepare(cand, limit: limit)
            }.value
            guard !Task.isCancelled, records.loadGeneration == generation else { return }
            cache.setRendered(prepared, for: sel.row)
            version += 1
        }
    }

    // MARK: 顶栏

    private func bar(_ cand: TextCandidate, all: [TextCandidate], row: RecordRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.book.closed").foregroundStyle(.tint)
            if all.count > 1 {
                Picker("字段", selection: Binding<String>(
                    get: { cand.path },
                    set: { selectedPath = $0 }
                )) {
                    ForEach(all) { c in
                        Text("\(c.path) (\(c.length))").tag(c.path)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 300)
            } else {
                Text(cand.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(cand.path)
            }
            Spacer()
            Text("\(cand.length) 字符")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cand.text, forType: .string)
            } label: { Label("复制文本", systemImage: "doc.on.doc") }
                .controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func emptyState(_ title: String, _ hint: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "text.quote")
                .font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(hint).font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - 渲染（字面 \n 处理 + Markdown 三级回退）

enum TextRender {
    /// 字符串里没有真实换行却含有字面 \n / \t（JSON 双重转义的常见产物）时，
    /// 把它们还原为真实换行/制表符。
    static func unescapeLiteralIfNeeded(_ s: String) -> (text: String, converted: Bool) {
        let hasLiteral = s.contains("\\n") || s.contains("\\t") || s.contains("\\r")
        guard hasLiteral, !s.contains("\n") else { return (s, false) }
        var out = String()
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\", let next = s.index(i, offsetBy: 1, limitedBy: s.endIndex), next < s.endIndex {
                switch s[next] {
                case "n": out.append("\n"); i = s.index(after: next); continue
                case "t": out.append("\t"); i = s.index(after: next); continue
                case "r": out.append("\r"); i = s.index(after: next); continue
                case "\\": out.append("\\"); i = s.index(after: next); continue
                default: break
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return (out, true)
    }

    /// 用自研块级渲染器渲染 Markdown（Foundation 的 .full 解析不产出可显示的
    /// 字体和换行，见 MarkdownRenderer 注释）。外层 XML 式包裹标签先剥离。
    static func render(_ source: String) -> (NSAttributedString, String) {
        let body = stripXmlWrapper(source)
        return (MarkdownRenderer.render(body), "Markdown")
    }

    private static let openTag = try! NSRegularExpression(pattern: #"^<([A-Za-z][A-Za-z0-9_-]*)>"#)
    private static let closeTag = try! NSRegularExpression(pattern: #"</([A-Za-z][A-Za-z0-9_-]*)>\s*$"#)

    static func stripXmlWrapper(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = t as NSString
        guard let m1 = openTag.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)),
              let r1 = Range(m1.range(at: 1), in: t),
              let m2 = closeTag.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)),
              let r2 = Range(m2.range(at: 1), in: t),
              t[r1] == t[r2],   // 首尾是同名标签才剥离
              m1.range.upperBound < m2.range.lowerBound else { return s }
        let inner = ns.substring(with: NSRange(location: m1.range.upperBound,
                                               length: m2.range.lowerBound - m1.range.upperBound))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? s : inner
    }

    struct Prepared {
        let path: String
        let attributed: NSAttributedString
        let mode: String
        let converted: Bool
        let truncated: Bool
    }

    /// 读行 + 解析 + 抽取文本字段（纯函数；大行放后台跑）
    static func loadCandidates(_ row: RecordRow, _ file: JsonlFile?) -> [TextCandidate] {
        guard let data = file?.readLine(offset: row.offset, length: row.length),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return [] }
        return TextExtractor.extract(root: obj)
    }

    /// 候选文本 → 渲染结果（截断保护 + 字面 \n 处理）
    static func prepare(_ cand: TextCandidate, limit: Int) -> Prepared {
        let (text, converted) = unescapeLiteralIfNeeded(cand.text)
        let truncated = text.count > limit
        let limited = truncated ? String(text.prefix(limit)) : text
        let (attr, mode) = render(limited)
        return Prepared(path: cand.path, attributed: attr, mode: mode,
                        converted: converted, truncated: truncated)
    }
}

/// 文本页的缓存：每行的文本字段、每个字段的渲染结果都只算一次，
/// 搜索框输入、悬停等引起的重新渲染只是取缓存，不再读文件、解析、渲染 Markdown。
///
/// 体积不大时在读取时同步算完（与最初的手感一致，只是不再每次渲染重算）；
/// 体积大时读取返回 nil，由视图的后台任务算好后存进来。
final class TextTabCache {
    /// 超过这个字节数的行改在后台读取
    static let syncReadLimit = 256 * 1024
    /// 超过这个字符数的字段改在后台渲染
    static let syncRenderLimit = 20_000
    /// 超过此长度截断渲染，避免超大文本拖垮 UI
    static let renderLimit = 500_000
    /// 最多保留最近几行，渲染结果可能很大
    private static let maxRows = 6

    private struct Entry {
        let candidates: [TextCandidate]
        var renders: [String: TextRender.Prepared] = [:]
    }
    private var entries: [Int: Entry] = [:]
    private var recent: [Int] = []
    private var token = -1

    /// 换了一份文件（或重新解析）后，按行号缓存的结果全部失效
    func sync(token: Int) {
        guard token != self.token else { return }
        self.token = token
        entries.removeAll()
        recent.removeAll()
    }

    /// 该行的文本字段；行太大且尚未在后台读出来时为 nil
    func candidates(for row: RecordRow, file: JsonlFile?) -> [TextCandidate]? {
        if let e = entries[row.id] { return e.candidates }
        guard row.length <= Self.syncReadLimit else { return nil }
        let list = TextRender.loadCandidates(row, file)
        store(row.id, Entry(candidates: list, renders: [:]))
        return list
    }

    func setCandidates(_ list: [TextCandidate], for rowID: Int) {
        store(rowID, Entry(candidates: list, renders: [:]))
    }

    /// 字段的渲染结果；文本太长且尚未在后台渲染完时为 nil
    func rendered(_ cand: TextCandidate, for row: RecordRow) -> TextRender.Prepared? {
        guard var e = entries[row.id] else { return nil }
        if let r = e.renders[cand.path] { return r }
        guard cand.length <= Self.syncRenderLimit else { return nil }
        let r = TextRender.prepare(cand, limit: Self.renderLimit)
        e.renders[cand.path] = r
        entries[row.id] = e
        return r
    }

    func setRendered(_ r: TextRender.Prepared, for row: RecordRow) {
        entries[row.id]?.renders[r.path] = r
    }

    private func store(_ rowID: Int, _ entry: Entry) {
        if entries[rowID] == nil {
            recent.append(rowID)
            while recent.count > Self.maxRows { entries[recent.removeFirst()] = nil }
        }
        entries[rowID] = entry
    }
}

/// 渲染结果 + 搜索高亮 + 模式徽标。
private struct ContentView: View {
    let rendered: NSAttributedString
    let mode: String
    let converted: Bool
    let truncated: Bool
    @Binding var searchText: String
    @Binding var matchIndex: Int

    private var matchCount: Int {
        HighlightedTextView.matchRanges(in: rendered.string, needle: searchText).count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(mode)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(.tint)
                    .help("渲染模式：完整 Markdown 优先，解析失败时回退到行内 Markdown 或纯文本")
                if converted {
                    Text("已将字面 \\n 转为换行")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(Color.orange.opacity(0.15)))
                        .foregroundStyle(.orange)
                }
                if truncated {
                    Text("已截断")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(0.15)))
                        .foregroundStyle(.secondary)
                        .help("超过 50 万字符截断渲染；复制文本可取全文")
                }
                Spacer()
                SearchBar(text: $searchText, matchIndex: $matchIndex, matchCount: matchCount)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            HighlightedTextView(attributed: rendered,
                                highlight: searchText,
                                matchIndex: matchIndex)
                .padding(6)
        }
    }
}
