import SwiftUI
import AppKit

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sessions: SessionStore

    var body: some View {
        ScrollViewReader { proxy in
            sidebarList
                .onChange(of: model.locateToken) { _ in
                    // 定位按钮：把文件列表滚回当前打开的文件
                    if let id = model.selectedFileID {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
        }
    }

    private var sidebarList: some View {
        List(selection: Binding<String?>(
            get: { model.selectedFileID },
            set: { id in
                if let id { model.open(URL(fileURLWithPath: id)) }
            }
        )) {
            if sessions.scanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在扫描会话目录…").font(.callout).foregroundStyle(.secondary)
                }
            }
            if !sessions.filteredExternal.isEmpty {
                Section("打开的文件") {
                    ForEach(sessions.filteredExternal) { f in
                        SidebarRow(file: f)
                            .tag(f.id)
                            .contextMenu { menuItems(for: f) }
                    }
                }
            }
            ForEach(sessions.filteredGroups) { g in
                Section {
                    ForEach(g.files) { f in
                        SidebarRow(file: f)
                            .tag(f.id)
                            .contextMenu { menuItems(for: f) }
                    }
                } header: {
                    sidebarHeader(g)
                }
            }
            if !sessions.scanning, sessions.groups.isEmpty, sessions.external.isEmpty {
                Text("未发现会话文件。\n可将 .jsonl / .zstd 文件拖入窗口。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $sessions.search, placement: .sidebar, prompt: "搜索路径或名称")
        .safeAreaInset(edge: .top, spacing: 0) {
            filterRow
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                if sessions.isFilterActive || !sessions.search.isEmpty {
                    Text("\(sessions.filteredGroups.count) 组 · \(sessions.filteredGroups.reduce(0) { $0 + $1.files.count }) 文件")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("共 \(sessions.files.count)")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    Text("\(sessions.groups.count) 个工作区 · \(sessions.files.count) 个文件")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    sessions.rescan()
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("重新扫描 ~/.dsh/sessions、~/.codex/sessions 与 ~/.claude/projects")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.bar)
        }
    }

    // MARK: 筛选/排序控件

    private var sortSummary: String {
        switch (sessions.groupSort, sessions.fileSort) {
        case (.recent, .modified): return "默认"
        case (.recent, let f): return "活动·\(f.rawValue)"
        case (let g, .modified): return "\(g.rawValue)·时间"
        case (let g, let f): return "\(g.rawValue)·\(f.rawValue)"
        }
    }

    private func menuLabel(_ icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.caption2)
            Text(value).font(.caption)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.6)))
        .contentShape(Rectangle())
    }

    private var filterRow: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("来源", selection: $sessions.sourceFilter) {
                    Text("全部来源").tag(SessionSource?.none)
                    Text("DSH").tag(SessionSource?.some(.dsh))
                    Text("Codex").tag(SessionSource?.some(.codex))
                    Text("Claude").tag(SessionSource?.some(.claude))
                }
            } label: {
                menuLabel("arrow.triangle.branch", value: "来源·\(sessions.sourceFilter?.rawValue ?? "全部")")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("按会话来源筛选")

            Menu {
                Picker("时间", selection: $sessions.timeFilter) {
                    ForEach(SessionTimeFilter.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                menuLabel("clock", value: "时间·\(sessions.timeFilter.rawValue)")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("按最近修改时间筛选")

            Menu {
                Section("分组排序") {
                    Picker("分组", selection: $sessions.groupSort) {
                        ForEach(SessionGroupSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("组内排序") {
                    Picker("组内", selection: $sessions.fileSort) {
                        ForEach(SessionFileSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            } label: {
                menuLabel("arrow.up.arrow.down", value: sortSummary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("排序方式")

            Spacer(minLength: 0)
            if sessions.isFilterActive {
                Button {
                    sessions.sourceFilter = nil
                    sessions.timeFilter = .all
                    sessions.groupSort = .recent
                    sessions.fileSort = .modified
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .help("重置筛选与排序")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: 右键菜单

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// 解析文件的真实工作区路径：
    /// 1. 同组里有 Codex/Claude 的真实 cwd 时直接用（分组显示名已被升级为真路径）
    /// 2. DSH 会话首行 session 头里有 "cwd" 字段（zstd 文件经缓存解压后读取）
    /// 3. 兜底：文件自身的 slug 还原结果
    private func resolvedWorkspace(for f: SessionFile) -> String? {
        if let g = sessions.groups.first(where: { $0.files.contains { $0.id == f.id } }),
           let real = g.files.first(where: { !$0.isSlugWorkspace })?.workspace {
            return real
        }
        if f.source == .dsh, let real = dshHeadCwd(f) {
            return real
        }
        return f.workspace
    }

    /// DSH 会话文件首行：{"type":"session",…,"cwd":"/Users/…/xxx",…}
    private func dshHeadCwd(_ f: SessionFile) -> String? {
        guard let prepared = try? JsonlFile.prepare(f.url),
              let reader = prepared.openReader(),
              let (line, _) = reader.nextLine() else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let cwd = obj["cwd"] as? String, !cwd.isEmpty else { return nil }
        return cwd
    }

    @ViewBuilder
    private func menuItems(for f: SessionFile) -> some View {
        Button {
            copyToPasteboard(f.id)
        } label: {
            Label("复制文件路径", systemImage: "doc.on.doc")
        }
        .help(f.id)
        if f.workspace != nil {
            Button {
                if let ws = resolvedWorkspace(for: f) {
                    copyToPasteboard(ws)
                }
            } label: {
                Label("复制工作区路径", systemImage: "folder.on.folder")
            }
            .help("优先使用分组里的真实 cwd；DSH 独立分组时读取会话首行的 cwd 字段")
        }
        Divider()
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([f.url])
        } label: {
            Label("在 Finder 中显示", systemImage: "folder")
        }
    }

    private func sidebarHeader(_ g: WorkspaceGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.caption2)
                .foregroundStyle(.tint)
            Text(shortWorkspace(g.name))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(g.name)
            Spacer()
            Text(countLabel(g))
                .font(.caption2).foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func countLabel(_ g: WorkspaceGroup) -> String {
        var parts: [String] = []
        for src in [SessionSource.dsh, .codex, .claude] {
            let n = g.files.filter { $0.source == src }.count
            if n > 0 { parts.append("\(src.rawValue) \(n)") }
        }
        return parts.joined(separator: " · ")
    }

    /// 组名缩短显示：家目录前缀换 ~，只保留最后三段路径，完整路径悬停可见
    private func shortWorkspace(_ ws: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var s = ws.hasPrefix(home) ? "~" + ws.dropFirst(home.count) : ws
        let parts = s.split(separator: "/").map(String.init)
        if parts.count > 3 {
            s = "…" + parts.suffix(3).joined(separator: "/")
        }
        return s
    }
}

private struct SidebarRow: View {
    let file: SessionFile

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                SourceTag(source: file.source)
                Text(file.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if file.isZstd {
                    Text("zstd")
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                Text(Fmt.size(file.size))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(file.detail)
                .font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
            Text(file.mtime.formatted(.relative(presentation: .named)))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
        .help(file.id)
    }
}

private struct SourceTag: View {
    let source: SessionSource

    var color: Color {
        switch source {
        case .dsh: return .blue
        case .codex: return .green
        case .claude: return .teal
        case .other: return .purple
        }
    }

    var body: some View {
        Text(source.rawValue)
            .font(.system(size: 8, weight: .semibold))
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}
