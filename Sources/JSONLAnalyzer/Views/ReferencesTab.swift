import SwiftUI

/// 记录详情的"关联"标签页：跨记录引用关系。
/// DSH：sequence 引用（throughSeq / messageSeqs / seq_from…）。
/// Codex：call_id 工具调用配对、同 turn 记录、压缩点、fork 来源。
/// 点击任一条目跳转并压入返回栈，顶栏按钮返回。
struct ReferencesTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var records: RecordStore
    @EnvironmentObject private var sessions: SessionStore

    private let displayCap = 500

    var body: some View {
        Group {
            if let row = model.selectedRow {
                content(row)
            } else {
                emptyState("未选择记录", "在中间列表选择一行后，这里展示它的引用关系")
            }
        }
    }

    // MARK: 内容

    private func content(_ row: RecordRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                bar(row)
                callPairSection(row)
                if let seq = row.seq, records.indexes.rowRefs.isEmpty == false || !records.indexes.refIndex.isEmpty {
                    incomingSection(row, seq: seq)
                    outgoingSection(row)
                }
                sameTurnSection(row)
                forkSection
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bar(_ row: RecordRow) -> some View {
        HStack(spacing: 10) {
            TypeBadge(text: row.typeLabel, invalid: row.isInvalid)
            Text("行 \(row.id)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let seq = row.seq {
                Text("序号 \(seq)")
                    .font(.system(size: 11, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(.tint)
            }
            if let t = row.time {
                Text(Fmt.timeOfDay.string(from: t))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.navigateBack()
            } label: {
                Label("返回", systemImage: "chevron.backward")
            }
            .controlSize(.small)
            .disabled(model.navBackStack.isEmpty)
            .help("返回导航前的记录（\(model.navBackStack.count) 层）")
            Button {
                model.locateSelection()
            } label: {
                Image(systemName: "target")
            }
            .controlSize(.small)
            .help("在记录列表中定位当前行")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background))
    }

    // MARK: Codex：call_id 工具调用配对

    @ViewBuilder
    private func callPairSection(_ row: RecordRow) -> some View {
        if let call = records.indexes.rowCalls[row.id] {
            callPairContent(call)
        }
    }

    private func callPairContent(_ call: CallRef) -> some View {
        let partners: [(Int, String)]
        switch call.role {
        case .call:
            partners = (records.indexes.outputIndex[call.callId] ?? []).map { ($0, "输出") }
        case .output:
            partners = records.indexes.callIndex[call.callId].map { [($0, "调用")] } ?? []
        }
        return VStack(alignment: .leading, spacing: 6) {
            header("工具调用配对", detail: "call_id \(call.callId) · \(call.variant)")
            if partners.isEmpty {
                Text("未找到配对记录（调用可能被中断或输出来自 event_msg）")
                    .font(.callout).foregroundStyle(.tertiary)
            } else {
                ForEach(partners, id: \.0) { line, tag in
                    if let target = records.rows.first(where: { $0.id == line }) {
                        refRow(target, detail: tag)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background))
    }

    // MARK: DSH：sequence 引用

    private func incomingSection(_ row: RecordRow, seq: Int64) -> some View {
        let entries = (records.indexes.refIndex[seq] ?? []).filter { $0 != row.id }.sorted()
        return section(title: "引用了序号 \(seq) 的记录", count: entries.count) {
            ForEach(entries.prefix(displayCap), id: \.self) { line in
                if let target = records.rows.first(where: { $0.id == line }) {
                    refRow(target, detail: refPathDescription(line, seq: seq))
                }
            }
            if entries.count > displayCap {
                Text("…另有 \(entries.count - displayCap) 条")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        } empty: {
            Text("没有其他记录引用这个序号")
                .font(.callout).foregroundStyle(.tertiary)
        }
    }

    private func refPathDescription(_ line: Int, seq: Int64) -> String {
        let refs = records.indexes.rowRefs[line] ?? []
        let paths = refs.filter { $0.seqs.contains(seq) }.map(\.path)
        return paths.isEmpty ? "seq" : paths.joined(separator: ", ")
    }

    private func outgoingSection(_ row: RecordRow) -> some View {
        let refs = records.indexes.rowRefs[row.id] ?? []
        return section(title: "当前记录引用的序号", count: refs.count) {
            ForEach(refs, id: \.path) { ref in
                VStack(alignment: .leading, spacing: 3) {
                    Text(ref.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    ForEach(ref.seqs, id: \.self) { seq in
                        if let line = records.indexes.seqIndex[seq],
                           let target = records.rows.first(where: { $0.id == line }) {
                            refRow(target, detail: "序号 \(seq)")
                        } else {
                            HStack(spacing: 8) {
                                Text("序号 \(seq)")
                                    .font(.system(size: 11, design: .monospaced))
                                Text("未找到对应记录").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } empty: {
            Text("该记录没有引用其他序号")
                .font(.callout).foregroundStyle(.tertiary)
        }
    }

    // MARK: Codex：同 turn / 压缩点

    private func sameTurnSection(_ row: RecordRow) -> some View {
        let span = records.indexes.turns.first { $0.startLine <= row.id && row.id <= $0.endLine }
        let compactions = records.indexes.compactionLines
        return section(title: "所在 Turn", count: span == nil ? 0 : 1) {
            if let span {
                Text("turn \(span.turnId.prefix(12))… · 行 \(span.startLine) – \(span.endLine)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let comp = compactions.first(where: { $0 > span.startLine && $0 <= span.endLine }) {
                    Text("⚠️ 行 \(comp) 发生上下文压缩，此前的原始历史已被替代")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button {
                    if let target = records.rows.first(where: { $0.id == span.startLine }) {
                        model.navigate(to: target)
                    }
                } label: {
                    Label("跳到 turn_context 行", systemImage: "arrow.turn.down.left")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
        } empty: {
            if records.indexes.turns.isEmpty {
                Text("该文件没有 turn_context 记录（DSH/Claude 或旧版 Codex）")
                    .font(.callout).foregroundStyle(.tertiary)
            } else {
                Text("该行不在任何 turn 区间内").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Codex：会话来源（fork / resume）

    @ViewBuilder
    private var forkSection: some View {
        if let file = sessions.files.first(where: { $0.id == model.selectedFileID })
            ?? sessions.external.first(where: { $0.id == model.selectedFileID }),
           let fork = file.forkInfo {
            // 父文件名形如 rollout-<ts>-<thread>_<rollout>.jsonl，含父 thread id
            let parent = sessions.files.first {
                $0.source == .codex && $0.url.lastPathComponent.contains(fork.parentId)
            }
            VStack(alignment: .leading, spacing: 6) {
                header("会话来源", detail: fork.description)
                if let parent {
                    Button {
                        model.open(parent.url)
                    } label: {
                        Label("打开父会话 · \(parent.name)", systemImage: "arrow.turn.up.left")
                    }
                    .controlSize(.small)
                } else {
                    Text("父会话不在已扫描的目录中")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background))
        }
    }

    // MARK: 复用

    private func header(_ title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            Text(detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func refRow(_ target: RecordRow, detail: String) -> some View {
        Button {
            model.navigate(to: target)
        } label: {
            HStack(spacing: 8) {
                Text("\(target.id)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(width: 44, alignment: .trailing)
                TypeBadge(text: target.typeLabel, invalid: target.isInvalid)
                    .frame(width: 170, alignment: .leading)
                if let t = target.time {
                    Text(Fmt.timeOfDay.string(from: t))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 88, alignment: .leading)
                }
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(target.preview)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.03))
        )
        .help("点击跳转到第 \(target.id) 行")
    }

    @ViewBuilder
    private func section<Content: View, Empty: View>(
        title: String, count: Int,
        @ViewBuilder content: () -> Content,
        @ViewBuilder empty: () -> Empty
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if count > 0 {
                content()
            } else {
                empty()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background))
    }

    private func emptyState(_ title: String, _ hint: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "link.circle")
                .font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(hint).font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
