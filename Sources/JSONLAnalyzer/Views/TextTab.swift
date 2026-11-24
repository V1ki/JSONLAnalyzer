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

    /// 超过此长度截断渲染，避免超大文本拖垮 UI
    private let renderLimit = 500_000

    private var candidates: [TextCandidate] {
        guard let row = model.selectedRow,
              let data = records.rawData(for: row),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return [] }
        return TextExtractor.extract(root: obj)
    }

    private var selected: TextCandidate? {
        let list = candidates
        guard !list.isEmpty else { return nil }
        return list.first { $0.path == selectedPath } ?? list[0]
    }

    var body: some View {
        Group {
            if let row = model.selectedRow {
                if let cand = selected {
                    VStack(spacing: 0) {
                        bar(cand, all: candidates, row: row)
                        Divider()
                        TextRenderer(cand: cand, limit: renderLimit) { rendered, mode, converted, truncated in
                            ContentView(rendered: rendered, mode: mode, converted: converted,
                                        truncated: truncated,
                                        searchText: $searchText, matchIndex: $matchIndex)
                        }
                        .id(row.id)
                    }
                } else {
                    emptyState("该行没有可展示的文本字段",
                               "抽取规则：对象字段含换行、长度 ≥ 60，或字段名为 text/content/message 等且长度 ≥ 8；数组内字符串元素需 ≥ 60")
                }
            } else {
                emptyState("未选择记录", "在中间列表选择一行后，这里会把其中的长文本字段按 Markdown 渲染")
            }
        }
    }

    // MARK: 顶栏

    private func bar(_ cand: TextCandidate, all: [TextCandidate], row: RecordRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.book.closed").foregroundStyle(.tint)
            if all.count > 1 {
                Picker("字段", selection: Binding<String>(
                    get: { selected?.path ?? cand.path },
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

    /// 补齐 Markdown 解析结果里缺失的正文字体与颜色（保留标题/代码块的既有样式）。
    // （渲染已改由 MarkdownRenderer 完成，Foundation 解析路径不再使用。）
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

/// 把候选文本同步渲染成 NSAttributedString（截断保护 + 字面 \n 处理 + 分级回退）。
private struct TextRenderer<Content: View>: View {
    let cand: TextCandidate
    let limit: Int
    @ViewBuilder let content: (NSAttributedString, String, Bool, Bool) -> Content

    var body: some View {
        let (text, converted) = TextRender.unescapeLiteralIfNeeded(cand.text)
        let truncated = text.count > limit
        let limited = truncated ? String(text.prefix(limit)) : text
        let (attr, mode) = TextRender.render(limited)
        content(attr, mode, converted, truncated)
    }
}
