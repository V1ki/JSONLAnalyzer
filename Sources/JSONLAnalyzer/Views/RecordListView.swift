import SwiftUI
import AppKit

struct RecordListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var records: RecordStore
    @FocusState private var jumpFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            if model.jumpVisible {
                jumpBar
                Divider()
            }
            Divider()
            content
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: ⌘G 跳转输入条

    private var jumpBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.to.line")
                .foregroundStyle(.tint)
            TextField("跳转到行（1 – \(max(records.rows.count, 1))）", text: $model.jumpText)
                .textFieldStyle(.roundedBorder)
                .focused($jumpFieldFocused)
                .frame(width: 220)
                .onSubmit {
                    if model.performJump() { model.jumpVisible = false }
                }
            Button("跳转") {
                if model.performJump() { model.jumpVisible = false }
            }
            .controlSize(.regular)
            Button("取消") { model.jumpVisible = false }
                .controlSize(.regular)
            Spacer()
            Text("回车跳转 · Esc 关闭")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.06))
        .onAppear { jumpFieldFocused = true }
        .onExitCommand { model.jumpVisible = false }
    }

    // MARK: 文件信息栏

    private var header: some View {
        HStack(spacing: 8) {
            if let id = model.selectedFileID {
                Image(systemName: "doc.text")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text((id as NSString).lastPathComponent)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(id)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                statusView
                Button {
                    model.reload()
                } label: { Image(systemName: "arrow.clockwise") }
                    .controlSize(.small)
                    .help("重新解析")
                Button {
                    model.revealInFinder()
                } label: { Image(systemName: "folder") }
                    .controlSize(.small)
                    .help("在 Finder 中显示")
            } else {
                Text("未选择文件")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var statusView: some View {
        switch records.state {
        case .idle:
            EmptyView()
        case .loading(let p, let lines):
            HStack(spacing: 6) {
                ProgressView(value: max(p, 0.02))
                    .progressViewStyle(.linear)
                    .frame(width: 90)
                Text("解析中 \(lines) 行 · \(Int(p * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .done:
            Text("\(records.overview.totalLines) 行 · 有效 \(records.overview.validLines) · 损坏 \(records.overview.invalidLines)")
                .font(.caption).foregroundStyle(.secondary)
                .monospacedDigit()
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption).foregroundStyle(.red)
                .lineLimit(1).truncationMode(.tail)
                .help(msg)
        }
    }

    // MARK: 过滤栏

    @State private var typePopoverVisible = false

    private var typeFilterLabel: String {
        let n = records.filter.types.count
        if n == 0 { return "类型·全部" }
        if n == 1, let only = records.filter.types.first { return "类型·\(only)" }
        return "类型·已选 \(n) 种"
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField("搜索内容 / 类型 / 行号", text: Binding(
                get: { records.filter.searchText },
                set: { records.filter.searchText = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)

            Button {
                typePopoverVisible = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "tag").font(.caption2)
                    Text(typeFilterLabel).font(.caption)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(records.filter.types.isEmpty
                          ? Color(nsColor: .quaternaryLabelColor).opacity(0.3)
                          : Color.accentColor.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $typePopoverVisible, arrowEdge: .bottom) {
                TypeFilterPopover(
                    types: records.availableTypes,
                    selected: Binding(
                        get: { records.filter.types },
                        set: { records.filter.types = $0 }
                    ))
            }
            .help("按类型筛选（可多选）")

            Toggle("只看损坏行", isOn: Binding(
                get: { records.filter.invalidOnly },
                set: { records.filter.invalidOnly = $0 }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(records.overview.invalidLines == 0)

            Spacer()
            if records.filter.isValidFilterActive {
                Text("\(records.visibleRows.count)/\(records.rows.count)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button("清除") {
                    records.filter = RecordFilter()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    // MARK: 列表（ScrollViewReader 支持程序化滚动到行）

    @ViewBuilder
    private var content: some View {
        if case .error = records.state {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30)).foregroundStyle(.orange)
                Text("无法解析该文件")
                    .font(.headline)
                if case .error(let msg) = records.state {
                    Text(msg).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if records.rows.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        columnHeader
                        ForEach(records.visibleRows) { r in
                            RecordRowLine(row: r,
                                          selected: r.id == model.selectedRow?.id)
                                .id(r.id)
                                .onTapGesture { model.selectedRow = r }
                        }
                    }
                }
                .onChange(of: model.jumpRequest) { req in
                    guard let req else { return }
                    // 行号即行 ID；等布局应用后滚动并居中
                    DispatchQueue.main.async {
                        proxy.scrollTo(req.line, anchor: .center)
                    }
                }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("行").frame(width: 42, alignment: .trailing)
            Text("类型").frame(width: 152, alignment: .leading)
            Text("时间").frame(width: 88, alignment: .leading)
            Text("大小").frame(width: 58, alignment: .trailing)
            Text("内容").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if case .loading = records.state {
                ProgressView("正在解析…")
            } else if model.selectedFileID == nil {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 34)).foregroundStyle(.secondary)
                Text("从左侧选择会话，或把 .jsonl / .zstd 文件拖到窗口里")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("（空文件）").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 类型多选弹层：类型内搜索 + 复选框列表 + 全部/完成。
private struct TypeFilterPopover: View {
    let types: [(String, Int)]
    @Binding var selected: Set<String>
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var visibleTypes: [(String, Int)] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return types }
        return types.filter { $0.0.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("筛选类型", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleTypes, id: \.0) { t, c in
                        Toggle(isOn: Binding(
                            get: { selected.contains(t) },
                            set: { on in
                                if on { selected.insert(t) } else { selected.remove(t) }
                            }
                        )) {
                            HStack(spacing: 6) {
                                TypeBadge(text: t)
                                Spacer()
                                Text("\(c)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .padding(.horizontal, 10).padding(.vertical, 2.5)
                        .contentShape(Rectangle())
                    }
                }
            }
            .frame(width: 300)
            .frame(maxHeight: 300)

            Divider()
            HStack {
                Button("显示全部") { selected = [] }
                    .controlSize(.small)
                Spacer()
                if !selected.isEmpty {
                    Text("已选 \(selected.count) 种")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }
}

/// 单行记录：列宽与 columnHeader 一致，支持悬停与选中高亮。
private struct RecordRowLine: View {
    let row: RecordRow
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text("\(row.id)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
            TypeBadge(text: row.typeLabel, invalid: row.isInvalid)
                .frame(width: 152, alignment: .leading)
            if let t = row.time {
                Text(Fmt.timeOfDay.string(from: t))
                    .font(.caption.monospacedDigit())
                    .frame(width: 88, alignment: .leading)
            } else {
                Text("—").foregroundStyle(.tertiary)
                    .frame(width: 88, alignment: .leading)
            }
            Text(Fmt.lineSize(row.length))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            Text(row.preview)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 2.5)
        .background(
            selected ? Color.accentColor.opacity(0.22)
                     : (hovering ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .id(row.id)
    }
}
