import Foundation

enum SessionSource: String, CaseIterable, Identifiable {
    case dsh = "DSH"
    case codex = "Codex"
    case claude = "Claude"
    case other = "打开的文件"
    var id: String { rawValue }

    var rootPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .dsh: return home + "/.dsh/sessions"
        case .codex: return home + "/.codex/sessions"
        case .claude: return home + "/.claude/projects"
        case .other: return nil
        }
    }
}

/// Codex 会话的 fork/引用信息（来自首行 session_meta）
struct SessionForkInfo: Hashable {
    /// forked_from_id（ThreadId）或 history_base 指向的父 rollout_id
    let parentId: String
    let forkedFromOrdinal: Int64?

    var description: String {
        var text = "fork 自 " + parentId.prefix(18) + "…"
        if let o = forkedFromOrdinal {
            text += " · 至 ordinal \(o)"
        }
        return text
    }
}

/// 侧栏里的一个会话文件（只含元数据，不读内容；workspace 除外——Codex 需要读文件头提取 cwd）。
struct SessionFile: Identifiable, Hashable {
    let id: String   // 完整路径
    let url: URL
    let name: String
    let detail: String
    let size: Int64
    let mtime: Date
    let isZstd: Bool
    let source: SessionSource
    /// 工作区路径：Codex 为文件里读到的真实 cwd；DSH 为目录 slug 的尽力还原
    let workspace: String?
    /// workspace 是否来自 slug 还原（用于同组里优先显示真实路径）
    let isSlugWorkspace: Bool
    /// Codex：fork / resume 来源（首行 session_meta 解析）
    let forkInfo: SessionForkInfo?

    static func == (lhs: SessionFile, rhs: SessionFile) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// 按 workspace 聚合的分组。
struct WorkspaceGroup: Identifiable {
    let id: String
    let name: String
    let files: [SessionFile]
    let latest: Date
}

// MARK: - 侧栏筛选/排序

enum SessionTimeFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case day = "24 小时"
    case week = "7 天"
    case month = "30 天"
    case quarter = "90 天"
    var id: String { rawValue }

    var cutoff: Date? {
        let cal = Calendar.current
        switch self {
        case .all: return nil
        case .day: return cal.date(byAdding: .hour, value: -24, to: Date())
        case .week: return cal.date(byAdding: .day, value: -7, to: Date())
        case .month: return cal.date(byAdding: .day, value: -30, to: Date())
        case .quarter: return cal.date(byAdding: .day, value: -90, to: Date())
        }
    }
}

enum SessionGroupSort: String, CaseIterable, Identifiable {
    case recent = "最近活动"
    case name = "名称"
    var id: String { rawValue }
}

enum SessionFileSort: String, CaseIterable, Identifiable {
    case modified = "修改时间"
    case name = "名称"
    case size = "大小"
    var id: String { rawValue }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var files: [SessionFile] = []
    @Published private(set) var groups: [WorkspaceGroup] = []
    /// 拖入/打开面板进来的文件（与扫描结果分开，避免点击选择时列表重排）
    @Published private(set) var external: [SessionFile] = []
    @Published private(set) var scanning = false
    @Published var search = ""

    // 筛选与排序（nil = 全部来源）
    @Published var sourceFilter: SessionSource?
    @Published var timeFilter: SessionTimeFilter = .all
    @Published var groupSort: SessionGroupSort = .recent
    @Published var fileSort: SessionFileSort = .modified

    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    // 过滤/排序结果缓存：输入不变时直接复用，万级文件也不重复计算
    private var groupsCacheKey = ""
    private var groupsCache: [WorkspaceGroup] = []
    private var externalCacheKey = ""
    private var externalCache: [SessionFile] = []

    var isFilterActive: Bool {
        sourceFilter != nil || timeFilter != .all
            || groupSort != .recent || fileSort != .modified
    }

    var filteredGroups: [WorkspaceGroup] {
        let key = "\(scanGeneration)|\(search)|\(sourceFilter?.rawValue ?? "-")|\(timeFilter.rawValue)|\(groupSort.rawValue)|\(fileSort.rawValue)"
        if key != groupsCacheKey {
            groupsCache = computeGroups()
            groupsCacheKey = key
        }
        return groupsCache
    }

    var filteredExternal: [SessionFile] {
        let key = "\(scanGeneration)|\(search)|\(timeFilter.rawValue)|\(fileSort.rawValue)"
        if key != externalCacheKey {
            externalCache = computeExternal()
            externalCacheKey = key
        }
        return externalCache
    }

    private func computeGroups() -> [WorkspaceGroup] {
        var pool = files
        if let src = sourceFilter {
            pool = pool.filter { $0.source == src }
        }
        if let cutoff = timeFilter.cutoff {
            pool = pool.filter { $0.mtime >= cutoff }
        }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            pool = pool.filter {
                $0.name.lowercased().contains(needle) || $0.id.lowercased().contains(needle)
            }
        }
        var gs = SessionStore.buildGroups(pool)
        gs.sort { a, b in
            switch groupSort {
            case .recent: return a.latest > b.latest
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        return gs.map { g in
            WorkspaceGroup(id: g.id, name: g.name, files: sortedFiles(g.files), latest: g.latest)
        }
    }

    private func sortedFiles(_ list: [SessionFile]) -> [SessionFile] {
        switch fileSort {
        case .modified: return list.sorted { $0.mtime > $1.mtime }
        case .name: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size: return list.sorted { $0.size != $1.size ? $0.size > $1.size : $0.mtime > $1.mtime }
        }
    }

    private func computeExternal() -> [SessionFile] {
        // 指定了来源筛选时隐藏"打开的文件"（它不属于三个会话来源）
        guard sourceFilter == nil else { return [] }
        var list = external
        if let cutoff = timeFilter.cutoff {
            list = list.filter { $0.mtime >= cutoff }
        }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(needle) || $0.id.lowercased().contains(needle)
            }
        }
        return sortedFiles(list)
    }

    func rescan() {
        scanTask?.cancel()
        scanning = true
        scanTask = Task.detached(priority: .utility) { [weak self] in
            var found: [SessionFile] = []
            for src in [SessionSource.dsh, .codex, .claude] {
                if Task.isCancelled { return }
                guard let root = src.rootPath else { continue }
                found.append(contentsOf: SessionStore.scanDirectory(
                    URL(fileURLWithPath: root), source: src))
            }
            found.sort { $0.mtime > $1.mtime }
            let groups = SessionStore.buildGroups(found)
            await self?.setScanResult(files: found, groups: groups)
        }
    }

    private func setScanResult(files: [SessionFile], groups: [WorkspaceGroup]) {
        self.files = files
        self.groups = groups
        self.scanning = false
        scanGeneration += 1
    }

    /// 供"打开的文件"分组：只新增扫描结果里没有的路径；不打乱扫描结果顺序。
    func insertExternal(_ url: URL) {
        let path = url.path
        guard !files.contains(where: { $0.id == path }) else { return }
        external.removeAll { $0.id == path }
        external.insert(Self.makeEntry(url: url, source: .other), at: 0)
        scanGeneration += 1
    }

    // MARK: - 扫描

    nonisolated static func scanDirectory(_ root: URL, source: SessionSource) -> [SessionFile] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var out: [SessionFile] = []
        for case let url as URL in en {
            guard let vals = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard vals.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            let ok: Bool
            switch source {
            case .dsh: ok = ext == "jsonl" || ext == "zstd" || ext == "zst"
            case .codex: ok = ext == "jsonl" || ext == "json" || ext == "zstd" || ext == "zst"
            case .claude: ok = ext == "jsonl"
            case .other: ok = true
            }
            guard ok else { continue }
            out.append(makeEntry(url: url, source: source,
                                 size: Int64(vals.fileSize ?? 0),
                                 mtime: vals.contentModificationDate ?? .distantPast))
        }
        return out
    }

    nonisolated private static func makeEntry(url: URL, source: SessionSource,
                                              size: Int64? = nil, mtime: Date? = nil) -> SessionFile {
        let fm = FileManager.default
        let s = size ?? Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let m = mtime ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        let name: String
        let detail: String
        let workspace: String?
        let fork: SessionForkInfo?
        var slugWorkspace = false
        let comps = url.pathComponents
        let home = fm.homeDirectoryForCurrentUser.path

        if source == .dsh, comps.count >= 2 {
            // sessions/<cwd-slug>/<uuid>/session.v4.jsonl(.zstd)
            let slug = comps[comps.count - 3]
            let uuid = comps[comps.count - 2]
            workspace = decodeSlug(slug)
            slugWorkspace = true
            fork = nil
            name = String(uuid.prefix(8))
            detail = workspace ?? uuid
        } else if source == .codex {
            // rollout-2025-09-02T16-46-58-<uuid>.jsonl；workspace/fork 从文件头提取
            let base = url.deletingPathExtension().lastPathComponent
            if base.hasPrefix("rollout-") {
                let body = String(base.dropFirst("rollout-".count))
                if body.count > 36 {
                    let dt = String(body.dropLast(37)).replacingOccurrences(of: "T", with: " ")
                    let uuid = String(body.suffix(36)).prefix(8)
                    name = "\(dt) · \(uuid)"
                } else { name = body }
            } else { name = base }
            let head = headInfo(url)
            workspace = head.cwd
            slugWorkspace = false
            fork = head.fork
            detail = url.deletingLastPathComponent().path
                .replacingOccurrences(of: home, with: "~")
        } else if source == .claude {
            // projects/<cwd-slug>/<session-uuid>.jsonl；workspace/标题从文件头提取
            let base = url.deletingPathExtension().lastPathComponent
            let head = headInfo(url)
            if let title = head.summaryTitle {
                name = title.count > 44 ? String(title.prefix(44)) + "…" : title
            } else {
                name = String(base.prefix(8))
            }
            workspace = head.cwd
            slugWorkspace = false
            fork = nil
            detail = workspace ?? url.deletingLastPathComponent().lastPathComponent
        } else {
            name = url.lastPathComponent
            workspace = nil
            slugWorkspace = false
            fork = nil
            detail = url.deletingLastPathComponent().path
                .replacingOccurrences(of: home, with: "~")
        }
        return SessionFile(id: url.path, url: url, name: name, detail: detail,
                           size: s, mtime: m,
                           isZstd: JsonlFile.isCompressedURL(url), source: source,
                           workspace: workspace, isSlugWorkspace: slugWorkspace,
                           forkInfo: fork)
    }

    /// 读取文件头部（32KB）得到的会话信息。
    struct HeadInfo {
        /// 工作区路径：Codex 来自 session_meta 的 "cwd"；Claude 来自消息行的 "cwd"；
        /// 旧版 Codex 在用户消息的 <cwd>...</cwd> 文本里
        var cwd: String?
        /// Claude 汇总行 {"type":"summary","summary":"…"} 的标题
        var summaryTitle: String?
        /// Codex 首行 session_meta 的 fork 来源
        var fork: SessionForkInfo?
    }

    nonisolated private static let cwdJSON = try! NSRegularExpression(pattern: #""cwd"\s*:\s*"([^"\\]+)""#)
    nonisolated private static let cwdTag = try! NSRegularExpression(pattern: #"<cwd>([^<]+)</cwd>"#)
    nonisolated private static let summaryJSON = try! NSRegularExpression(
        pattern: #""type"\s*:\s*"summary"\s*,\s*"summary"\s*:\s*"([^"\\]{0,80})""#)

    nonisolated private static func headInfo(_ url: URL) -> HeadInfo {
        guard !JsonlFile.isCompressedURL(url),
              let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 32 * 1024) else {
            return HeadInfo(cwd: nil, summaryTitle: nil, fork: nil)
        }
        try? handle.close()
        let s = String(decoding: head, as: UTF8.self)
        return HeadInfo(
            cwd: firstMatch(cwdJSON, in: s) ?? firstMatch(cwdTag, in: s),
            summaryTitle: firstMatch(summaryJSON, in: s),
            fork: parseForkInfo(s))
    }

    /// Codex 首行 session_meta：payload.forked_from_id / forked_from_ordinal_exclusive /
    /// history_base{thread_id, end_ordinal_exclusive}
    nonisolated private static func parseForkInfo(_ head: String) -> SessionForkInfo? {
        guard let firstLine = head.split(separator: "\n", maxSplits: 1).first,
              let obj = (try? JSONSerialization.jsonObject(with: Data(firstLine.utf8))) as? [String: Any],
              obj["type"] as? String == "session_meta",
              let payload = obj["payload"] as? [String: Any] else { return nil }
        var parentId = payload["forked_from_id"] as? String
        var ordinal = (payload["forked_from_ordinal_exclusive"] as? NSNumber)?.int64Value
        if let base = payload["history_base"] as? [String: Any] {
            if parentId == nil, let baseId = base["thread_id"] as? String {
                parentId = baseId
            }
            if ordinal == nil {
                ordinal = (base["end_ordinal_exclusive"] as? NSNumber)?.int64Value
            }
        }
        guard let parentId, !parentId.isEmpty else { return nil }
        return SessionForkInfo(parentId: parentId, forkedFromOrdinal: ordinal)
    }

    nonisolated private static func firstMatch(_ re: NSRegularExpression, in s: String) -> String? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    // MARK: - 分组

    /// 合并键：小写并去掉 "-" 和 "/"。
    /// DSH 目录 slug 无法区分组件内的连字符和路径分隔（dsh-pet 与 dsh/pet 同形），
    /// 去横杠比较能让 slug 还原结果与 Codex 真实 cwd 合并到同一组；
    /// 代价是仅相差连字符位置的两个不同路径会被并组，实际几乎不会遇到。
    nonisolated private static func mergeKey(_ ws: String) -> String {
        ws.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "/", with: "")
    }

    nonisolated static func buildGroups(_ files: [SessionFile]) -> [WorkspaceGroup] {
        struct Acc {
            var display: String
            var slugOnly: Bool
            var files: [SessionFile] = []
            var latest: Date = .distantPast
        }
        var acc: [String: Acc] = [:]
        var unknown: [SessionFile] = []
        for f in files {
            guard let ws = f.workspace else {
                unknown.append(f)
                continue
            }
            let key = mergeKey(ws)
            var a = acc[key] ?? Acc(display: ws, slugOnly: f.isSlugWorkspace)
            if a.slugOnly && !f.isSlugWorkspace {
                a.display = ws   // 同组里优先用真实路径做组名
                a.slugOnly = false
            }
            a.files.append(f)
            a.latest = max(a.latest, f.mtime)
            acc[key] = a
        }
        var out = acc.map { key, a in
            WorkspaceGroup(id: key, name: a.display,
                           files: a.files.sorted { $0.mtime > $1.mtime },
                           latest: a.latest)
        }.sorted { $0.latest > $1.latest }
        if !unknown.isEmpty {
            out.append(WorkspaceGroup(
                id: "§unknown", name: "未识别工作区",
                files: unknown.sorted { $0.mtime > $1.mtime },
                latest: unknown.map(\.mtime).max() ?? .distantPast))
        }
        return out
    }

    /// "--Users-v1ki-DSH-Pet-Workspace--" → "/Users-v1ki-DSH-Pet-Workspace"
    /// （连字符与分隔符无法区分，只做稳定还原，用于分组与显示）
    nonisolated private static func decodeSlug(_ slug: String) -> String? {
        var s = slug
        if s.hasPrefix("--") { s.removeFirst(2) }
        if s.hasSuffix("--") { s.removeLast(2) }
        guard !s.isEmpty else { return nil }
        return "/" + s.replacingOccurrences(of: "--", with: "/")
    }
}
