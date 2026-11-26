import SwiftUI

struct DetailTabs: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.selectedFileID == nil {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("选择一行查看详情，或切换上方标签查看统计")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 当前标签页放在 AppModel 里：选中记录行时要据此判断「会话」页是否正显示着
                TabView(selection: $model.detailTab) {
                    ConversationTab()
                        .tabItem { Label("会话", systemImage: "bubble.left.and.bubble.right") }
                        .tag(AppModel.conversationTab)
                    RecordDetailView()
                        .tabItem { Label("记录", systemImage: "doc.plaintext") }
                        .tag(AppModel.recordTab)
                    ReferencesTab()
                        .tabItem { Label("关联", systemImage: "link") }
                        .tag("refs")
                    TextTab()
                        .tabItem { Label("文本", systemImage: "text.book.closed") }
                        .tag("text")
                    OverviewTab()
                        .tabItem { Label("概览", systemImage: "chart.bar") }
                        .tag("overview")
                    FieldsTab()
                        .tabItem { Label("字段", systemImage: "list.bullet.indent") }
                        .tag("fields")
                    TimelineTab()
                        .tabItem { Label("时间线", systemImage: "chart.line.uptrend.xyaxis") }
                        .tag("timeline")
                }
                .padding(4)
            }
        }
    }
}

// MARK: - 记录详情

struct RecordDetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var records: RecordStore
    @State private var searchText = ""
    @State private var matchIndex = 0

    var body: some View {
        Group {
            if let row = model.selectedRow {
                VStack(spacing: 0) {
                    metaBar(row)
                    Divider()
                    // .id(row.id)：换行即换整个正文子视图，@State 归零，
                    // 不存在"meta 已换行、正文还是上一行"的陈旧窗口
                    RecordDetailBody(row: row, searchText: $searchText, matchIndex: $matchIndex)
                        .id(row.id)
                        .overlay(alignment: .bottomTrailing) {
                            Button {
                                model.locateSelection()
                            } label: {
                                Image(systemName: "target")
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(width: 30, height: 30)
                                    .background(Circle().fill(.regularMaterial))
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(12)
                            .help("定位：记录列表滚回第 \(row.id) 行，文件列表滚回当前文件（必要时清除筛选）")
                        }
                }
                .onChange(of: row.id) { _ in
                    searchText = ""
                    matchIndex = 0
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("在中间列表选择一行查看完整 JSON")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func metaBar(_ row: RecordRow) -> some View {
        HStack(spacing: 10) {
            TypeBadge(text: row.typeLabel, invalid: row.isInvalid)
            if let seq = row.seq {
                Text("seq \(seq)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let t = row.time {
                Text(Fmt.fullTime.string(from: t) + "."
                    + String(format: "%03d", Int(t.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) * 1000)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("行 \(row.id) · \(Fmt.lineSize(row.length))")
                .font(.caption).foregroundStyle(.secondary)

            if row.isInvalid, let msg = row.invalidMessage {
                Text(msg).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            Button {
                if let text = records.prettyJSON(for: row) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            } label: { Label("复制格式化", systemImage: "doc.on.doc") }
                .controlSize(.small)
            Button {
                if let data = records.rawData(for: row),
                   let text = String(data: data, encoding: .utf8) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            } label: { Label("复制原文", systemImage: "doc.on.clipboard") }
                .controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

/// 正文子视图：随行身份键控，内容用 .task(id:) 加载，JSON 支持点击折叠。
private struct RecordDetailBody: View {
    let row: RecordRow
    @Binding var searchText: String
    @Binding var matchIndex: Int

    @EnvironmentObject private var records: RecordStore
    @State private var pretty: String?
    @State private var collapsed: Set<Int> = []
    /// 超过此行数的 pretty JSON 打开时自动折叠到第一层
    private let autoFoldThreshold = 300

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            if let text = pretty {
                Group {
                    if row.isInvalid {
                        HighlightedTextView(
                            attributed: plainAttr(text),
                            highlight: searchText,
                            matchIndex: matchIndex
                        )
                    } else {
                        FoldableJsonTextView(
                            pretty: text,
                            collapsed: collapsed,
                            onToggle: toggleFold,
                            highlight: searchText,
                            matchIndex: matchIndex
                        )
                    }
                }
                .padding(6)
            } else {
                ProgressView("读取第 \(row.id) 行…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: row.id) {
            pretty = records.prettyJSON(for: row)
            applyAutoFold()
        }
    }

    private var controlBar: some View {
        HStack {
            SearchBar(text: $searchText, matchIndex: $matchIndex,
                      matchCount: HighlightedTextView
                          .matchRanges(in: pretty ?? "", needle: searchText).count)
            Spacer()
            if let text = pretty, !row.isInvalid {
                Button {
                    collapsed = Set(JsonFolder.folds(in: text).map(\.openLine))
                } label: {
                    Image(systemName: "rectangle.compress.vertical")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .help("全部折叠")
                Button {
                    collapsed = []
                } label: {
                    Image(systemName: "rectangle.expand.vertical")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .help("全部展开")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    private func toggleFold(_ openLine: Int) {
        if collapsed.contains(openLine) {
            collapsed.remove(openLine)
        } else {
            collapsed.insert(openLine)
        }
    }

    /// 大记录默认折叠到第一层（level ≥ 1 的容器收起，根对象保持展开）
    private func applyAutoFold() {
        guard let text = pretty else { return }
        let lineCount = text.components(separatedBy: "\n").count
        guard lineCount > autoFoldThreshold else { return }
        collapsed = Set(JsonFolder.folds(in: text)
            .filter { $0.level >= 1 }
            .map(\.openLine))
    }

    private func plainAttr(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
    }
}
