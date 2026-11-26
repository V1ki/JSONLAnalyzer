import SwiftUI

/// "会话"标签页：把 JSONL 还原成对话流（用户消息 / LLM 回复 / 推理 / 工具调用与输出 / 关键事件）。
struct ConversationTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var records: RecordStore
    @State private var entries: [ChatEntry] = []
    @State private var building = false
    /// 会话视图还没建好时收到的定位请求：要滚到的那一行，建好后处理
    @State private var pendingLine: Int?

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
                            ScrollViewReader { proxy in
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 10) {
                                        ForEach(entries) { e in
                                            let isCurrent = e.lineNo == model.selectedRow?.id
                                            ChatEntryView(entry: e, isCurrent: isCurrent) { row in
                                                if let target = records.rows.first(where: { $0.id == row }) {
                                                    // 请求来自会话视图自己：只跳记录列表，不回头滚动会话
                                                    model.navigate(to: target, revealInConversation: false)
                                                }
                                            }
                                            .id(e.id)
                                        }
                                    }
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .onAppear { scrollToPending(proxy) }
                                .onChange(of: pendingLine) { _ in scrollToPending(proxy) }
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
        // 记录列表里选中了另一行（或 ⌘G、关联跳转）：记下要定位的行，滚动视图在场时由它滚过去；
        // 条目还在构建时先记着，建好后再滚
        .onChange(of: model.conversationLocate) { req in
            pendingLine = req?.line
        }
        .task(id: "\(fileID)-\(records.rows.count)") {
            guard case .done = records.state, !records.rows.isEmpty else {
                entries = []
                building = false
                return
            }
            await rebuild()
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

    /// 后台逐行回读原始 JSON 并建条目（解析树用完即弃，内存不随文件大小增长）。
    /// `.task(id:)` 在切换文件或行数变化时取消本任务，取消会转给后台的那份工作。
    private func rebuild() async {
        building = true
        let file = records.file
        let rows = records.rows
        let work = Task.detached(priority: .userInitiated) {
            file.map { ConversationBuilder.buildStreaming($0, rows: rows) } ?? []
        }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        // 被取消说明已有新一轮构建：迟到的结果不覆盖它
        guard !Task.isCancelled else { return }
        entries = result ?? []
        building = false
    }

    /// 把待定位的那一行对应的条目滚到视图顶部（顶部对齐：条目再高，行号标签也在可见范围内）。
    private func scrollToPending(_ proxy: ScrollViewProxy) {
        guard let line = pendingLine else { return }
        pendingLine = nil
        guard let target = ConversationBuilder.nearestEntry(to: line, in: entries) else { return }
        // 等这一轮布局应用完再滚
        DispatchQueue.main.async {
            proxy.scrollTo(target.id, anchor: .top)
        }
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
    /// 这一条正是记录列表里选中的行：行号标签常亮，看得出会话视图滚到了哪一条
    var isCurrent = false
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
                    let lit = hovering || isCurrent
                    Text("行 \(entry.lineNo)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(lit ? Color.white : .secondary)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(lit ? Color.accentColor : Color.primary.opacity(0.06)))
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
