import SwiftUI

/// "会话"标签页：把 JSONL 还原成对话流（用户消息 / LLM 回复 / 推理 / 工具调用与输出 / 关键事件）。
struct ConversationTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var records: RecordStore
    @State private var entries: [ChatEntry] = []
    @State private var building = false
    @State private var buildToken = ""

    var body: some View {
        Group {
            if let fileID = model.selectedFileID {
                content(fileID: fileID)
            } else {
                emptyState("未选择会话", "打开左侧会话后，这里按对话顺序还原用户消息、LLM 回复与工具调用")
            }
        }
    }

    private func content(fileID: String) -> some View {
        Group {
            if case .done = records.state {
                if entries.isEmpty && !building {
                    emptyState("没有可还原的对话内容",
                               "该文件只包含元数据行，或来源格式暂不支持（当前支持 DSH / Codex / Claude）")
                } else {
                    VStack(spacing: 0) {
                        summaryBar
                        Divider()
                        if building {
                            ProgressView("还原对话中…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(entries) { e in
                                        ChatEntryView(entry: e) { row in
                                            if let target = records.rows.first(where: { $0.id == row }) {
                                                model.navigate(to: target)
                                            }
                                        }
                                    }
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            } else if case .error = records.state {
                emptyState("文件解析失败", "")
            } else {
                ProgressView("解析中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(fileID)-\(records.rows.count)") {
            guard case .done = records.state, !records.rows.isEmpty else {
                entries = []
                return
            }
            buildToken = "\(fileID)-\(records.rows.count)"
            await rebuild(fileID: fileID)
        }
    }

    private var summaryBar: some View {
        let users = entries.filter { $0.kind == .user }.count
        let assistants = entries.filter { $0.kind == .assistant }.count
        let tools = entries.filter { $0.kind == .toolCall || $0.kind == .toolOutput }.count
        return HStack(spacing: 10) {
            Label("\(users)", systemImage: "person")
            Label("\(assistants)", systemImage: "sparkles")
            Label("\(tools)", systemImage: "wrench.and.screwdriver")
            Text("共 \(entries.count) 条")
            Spacer()
            Text("点击条目标签跳到对应行")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    /// 后台把每行原始 JSON 解析后交给 ConversationBuilder
    private func rebuild(fileID: String) async {
        building = true
        let rows = records.rows
        let raw: (RecordRow) -> [String: Any]? = { row in
            guard let data = records.rawData(for: row) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        let result: [ChatEntry] = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var pairs: [(row: RecordRow, dict: [String: Any])] = []
                pairs.reserveCapacity(rows.count)
                for r in rows {
                    if let d = raw(r) { pairs.append((r, d)) }
                }
                cont.resume(returning: ConversationBuilder.build(pairs))
            }
        }
        guard buildToken == "\(fileID)-\(records.rows.count)" else {
            building = false
            return
        }
        entries = result
        building = false
    }

    private func emptyState(_ title: String, _ hint: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(title).font(.callout).foregroundStyle(.secondary)
            if !hint.isEmpty {
                Text(hint).font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - 单条气泡

private struct ChatEntryView: View {
    let entry: ChatEntry
    let onJump: (Int) -> Void
    @State private var expanded = false
    @State private var hovering = false

    private var roleTag: String {
        switch entry.kind {
        case .user: return "用户"
        case .assistant: return "助手"
        case .reasoning: return "推理"
        case .toolCall: return "调用"
        case .toolOutput: return "输出"
        case .marker: return ""
        }
    }

    private var roleColor: Color {
        switch entry.kind {
        case .user: return .blue
        case .assistant: return .green
        case .reasoning: return .orange
        case .toolCall: return .purple
        case .toolOutput: return .teal
        case .marker: return .secondary
        }
    }

    var body: some View {
        if entry.kind == .marker {
            HStack(spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 0.7).frame(maxWidth: .infinity)
                Text(entry.title ?? "")
                    .font(.caption2).foregroundStyle(.secondary)
                if !entry.body.isEmpty {
                    Text(entry.body)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 0.7).frame(maxWidth: .infinity)
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("行 \(entry.lineNo)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(hovering ? Color.white : .secondary)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(hovering ? Color.accentColor : Color.primary.opacity(0.06)))
                    if let t = entry.time {
                        Text(Fmt.timeOfDay.string(from: t))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(roleTag)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1.5)
                            .background(Capsule().fill(roleColor.opacity(0.16)))
                            .foregroundStyle(roleColor)
                        if let title = entry.title, !title.isEmpty {
                            Text(title)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        if let meta = entry.meta, !meta.isEmpty {
                            Text(meta)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if !entry.body.isEmpty {
                        bodyView
                    }
                }
                .padding(10)
                .frame(maxWidth: 660, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(bubbleBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(hovering ? Color.accentColor.opacity(0.5) : .clear,
                                      lineWidth: 1)
                )
            }
            .contentShape(Rectangle())
            .onTapGesture { onJump(entry.lineNo) }
            .onHover { hovering = $0 }
            .help("点击跳到记录列表第 \(entry.lineNo) 行")
        }
    }

    @ViewBuilder
    private var bodyView: some View {
        let mono = entry.kind == .toolCall || entry.kind == .toolOutput
        let long = entry.body.count > 600 || entry.body.components(separatedBy: "\n").count > 12
        Group {
            if mono {
                Text(expanded ? entry.body : truncatedBody)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
            } else if entry.kind == .reasoning {
                Text(expanded ? entry.body : truncatedBody)
                    .font(.system(size: 11.5))
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text(entry.body)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottomTrailing) {
            if long {
                Button(expanded ? "收起" : "展开") {
                    expanded.toggle()
                }
                .font(.caption2)
                .buttonStyle(.link)
                .controlSize(.mini)
                .padding(4)
                .background(.regularMaterial, in: Capsule())
            }
        }
    }

    private var truncatedBody: String {
        let lines = entry.body.components(separatedBy: "\n")
        if lines.count > 12 {
            return lines.prefix(12).joined(separator: "\n") + "\n…"
        }
        return String(entry.body.prefix(600)) + "…"
    }

    private var bubbleBackground: Color {
        switch entry.kind {
        case .user: return Color.blue.opacity(0.08)
        case .assistant: return Color(nsColor: .controlBackgroundColor)
        case .reasoning: return Color.orange.opacity(0.05)
        case .toolCall: return Color.purple.opacity(0.06)
        case .toolOutput: return Color.teal.opacity(0.06)
        case .marker: return .clear
        }
    }
}
