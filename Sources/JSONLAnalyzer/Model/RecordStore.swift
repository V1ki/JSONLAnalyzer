import Foundation
import SwiftUI

enum LoadState: Equatable {
    case idle
    case loading(progress: Double, lines: Int)
    case done
    case error(String)
}

/// 过滤条件
struct RecordFilter: Equatable {
    var searchText = ""
    /// 选中的类型；空集合 = 全部类型
    var types: Set<String> = []
    var invalidOnly = false
    var isValidFilterActive: Bool {
        !searchText.isEmpty || !types.isEmpty || invalidOnly
    }
}

/// 一个 turn 的行区间（Codex：turn_context 行到下一个 turn_context 行之前）
struct TurnSpan: Equatable {
    let turnId: String
    let startLine: Int
    var endLine: Int
}

/// 关联索引（解析时构建）
struct ParseIndexes {
    /// DSH：seq → 该序号所在行号（首个出现）
    var seqIndex: [Int64: Int] = [:]
    /// DSH：被引用的 seq → 引用它的行号列表
    var refIndex: [Int64: [Int]] = [:]
    /// DSH：行号 → 出向引用
    var rowRefs: [Int: [SeqRef]] = [:]
    /// Codex：callId → 调用行（function_call 等）
    var callIndex: [String: Int] = [:]
    /// Codex：callId → 输出行列表（function_call_output 等）
    var outputIndex: [String: [Int]] = [:]
    /// Codex：行号 → 该行的 call_id 信息
    var rowCalls: [Int: CallRef] = [:]
    /// Codex：turn 区间（按 turn_context 分段）
    var turns: [TurnSpan] = []
    /// Codex：compacted 行号列表（历史重置点）
    var compactionLines: [Int] = []
}

/// 当前打开文件的解析结果与状态。
@MainActor
final class RecordStore: ObservableObject {
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var rows: [RecordRow] = []
    @Published private(set) var visibleRows: [RecordRow] = []
    @Published private(set) var overview = OverviewStats()
    @Published private(set) var fields: [FieldStats] = []
    @Published private(set) var durations: [DurationEntry] = []
    @Published private(set) var tokenPoints: [TokenPoint] = []
    @Published private(set) var indexes = ParseIndexes()
    @Published var filter = RecordFilter() {
        didSet { recomputeVisible() }
    }

    private(set) var file: JsonlFile?
    private var loadTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    /// 每次 load / beginPreparing 递增。cancel() 只能让任务在下一次检查时停下，
    /// 手里那一轮已经算完的结果仍会送达——publish / finish 按这个编号丢弃迟到的那一份。
    private var loadGeneration = 0
    /// 每次 recomputeVisible 递增，作用同上：被取代的筛选任务迟到的结果不覆盖当前列表。
    private var filterGeneration = 0

    var availableTypes: [(String, Int)] {
        overview.typeCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    func load(_ f: JsonlFile) {
        loadTask?.cancel()
        filterTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        file = f
        rows = []; visibleRows = []; fields = []; durations = []; tokenPoints = []
        indexes = ParseIndexes()
        overview = OverviewStats()
        filter = RecordFilter()
        state = .loading(progress: 0, lines: 0)

        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let reader = f.openReader() else {
                await self?.finish(.error("无法打开文件：\(f.dataURL.path)"), generation: generation)
                return
            }
            var rows: [RecordRow] = []
            rows.reserveCapacity(4096)
            var ov = OverviewStats()
            var fa = FieldAnalyzer()
            var points: [TokenPoint] = []
            var intern: [String: String] = [:]
            var idx = ParseIndexes()

            var number = 0
            var published = 0
            while let (line, offset) = reader.nextLine() {
                if Task.isCancelled { return }
                number += 1
                var row = LineParser.parse(line: line, number: number, offset: offset)

                if !row.isInvalid, let data = try? JSONSerialization.jsonObject(with: Data(line)) {
                    ov.validLines += 1
                    fa.accumulate(root: data)
                    if let t = row.type { intern[t] = (intern[t] ?? t); row.type = intern[t] }
                    if let time = row.time {
                        if ov.firstTime == nil || time < ov.firstTime! { ov.firstTime = time }
                        if ov.lastTime == nil || time > ov.lastTime! { ov.lastTime = time }
                    }
                    if let dict = data as? [String: Any] {
                        // Token 口径：token_usage_record 只认 payload.usage；
                        // token_count/compacted 是累计快照，跳过
                        var found: [String: Double] = [:]
                        if row.type == "token_usage_record" {
                            found = TokenUsageRules.normalize(
                                TokenUsageRules.exactUsage(dict: dict))
                        } else if !TokenUsageRules.skipGenericScan(type: row.type,
                                                                   subtype: row.subtype) {
                            TokenScanner.scan(dict, depth: 0, found: &found)
                        }
                        if !found.isEmpty {
                            for (k, v) in found { ov.tokenTotals[k, default: 0] += v }
                            if points.count < 5000 {
                                points.append(TokenPoint(
                                    id: points.count, time: row.time,
                                    input: found["输入"] ?? 0, output: found["输出"] ?? 0))
                            }
                        }
                        // DSH sequence 引用索引
                        let rowRefList = SeqRefScanner.scan(dict)
                        if !rowRefList.isEmpty {
                            idx.rowRefs[number] = rowRefList
                            for r in rowRefList {
                                for s in r.seqs where s != row.seq {
                                    if idx.refIndex[s]?.count ?? 0 < 5000 {
                                        idx.refIndex[s, default: []].append(number)
                                    }
                                }
                            }
                        }
                        if let sq = row.seq, idx.seqIndex[sq] == nil {
                            idx.seqIndex[sq] = number
                        }
                        // Codex call_id 配对
                        if let callRef = CallRefScanner.scan(dict: dict) {
                            idx.rowCalls[number] = callRef
                            switch callRef.role {
                            case .call:
                                if idx.callIndex[callRef.callId] == nil {
                                    idx.callIndex[callRef.callId] = number
                                }
                            case .output:
                                if idx.outputIndex[callRef.callId]?.count ?? 0 < 100 {
                                    idx.outputIndex[callRef.callId, default: []].append(number)
                                }
                            }
                        }
                        // Codex turn 区间 / 压缩点
                        if row.type == "turn_context",
                           let payload = dict["payload"] as? [String: Any],
                           let turnId = payload["turn_id"] as? String {
                            if !idx.turns.isEmpty {
                                idx.turns[idx.turns.count - 1].endLine = number - 1
                            }
                            idx.turns.append(TurnSpan(turnId: turnId, startLine: number, endLine: number))
                        } else if row.type == "compacted" {
                            idx.compactionLines.append(number)
                            if !idx.turns.isEmpty {
                                idx.turns[idx.turns.count - 1].endLine = number - 1
                            }
                        }
                    }
                    if let t = row.type { ov.typeCounts[t, default: 0] += 1 }
                } else {
                    ov.invalidLines += 1
                }
                ov.totalLines = number
                ov.maxLineLength = max(ov.maxLineLength, row.length)
                rows.append(row)

                if number - published >= 2000 {
                    published = number
                    let progress = reader.totalBytes > 0
                        ? Double(reader.consumedBytes) / Double(reader.totalBytes) : 0
                    await self?.publish(rows: rows, overview: ov, progress: min(progress, 0.999),
                                        generation: generation)
                }
            }
            if Task.isCancelled { return }
            if !idx.turns.isEmpty {
                idx.turns[idx.turns.count - 1].endLine = number
            }

            let durs = DurationAnalyzer.pair(rows)
            let sortedFields = fa.sortedByCount
            await self?.finish(.done, rows: rows, overview: ov,
                               fields: sortedFields, durations: durs, points: points,
                               indexes: idx, generation: generation)
        }
    }

    /// 按当前行号取完整行数据（详情视图用）。
    func rawData(for row: RecordRow) -> Data? {
        file?.readLine(offset: row.offset, length: row.length)
    }

    func prettyJSON(for row: RecordRow) -> String? {
        guard let data = rawData(for: row) else { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           JSONSerialization.isValidJSONObject(obj),
           let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.prettyPrinted, .sortedKeys]) {
            return String(data: pretty, encoding: .utf8)
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - private

    /// 跳转到行前同步清空筛选（避免目标行被滤掉导致不可见）。
    /// 空筛选时 visibleRows == rows，无需异步重算。
    func resetFilterForJump() {
        guard filter.isValidFilterActive else { return }
        filterTask?.cancel()
        filter = RecordFilter()
        visibleRows = rows
    }

    /// 文件准备阶段（可能正在解压 zstd）：先进入加载态。
    func beginPreparing() {
        loadTask?.cancel()
        filterTask?.cancel()
        loadGeneration += 1
        rows = []; visibleRows = []; fields = []; durations = []; tokenPoints = []
        indexes = ParseIndexes()
        overview = OverviewStats()
        filter = RecordFilter()      // didSet → recomputeVisible()，在途的筛选任务随之失效
        state = .loading(progress: 0, lines: 0)
    }

    /// 打开/解压失败。
    func loadFailed(_ message: String) {
        state = .error(message)
    }

    private func publish(rows: [RecordRow], overview: OverviewStats, progress: Double,
                         generation: Int) {
        guard generation == loadGeneration else { return }
        self.rows = rows
        self.overview = overview
        state = .loading(progress: progress, lines: rows.count)
        recomputeVisible()
    }

    private func finish(_ s: LoadState, rows: [RecordRow] = [], overview: OverviewStats = OverviewStats(),
                        fields: [FieldStats] = [], durations: [DurationEntry] = [],
                        points: [TokenPoint] = [], indexes: ParseIndexes = ParseIndexes(),
                        generation: Int) {
        guard generation == loadGeneration else { return }
        state = s
        if case .done = s {
            self.rows = rows
            self.overview = overview
            self.fields = fields
            self.durations = durations
            self.tokenPoints = points
            self.indexes = indexes
            recomputeVisible()
        }
    }

    private func recomputeVisible() {
        let src = rows
        let f = filter
        filterTask?.cancel()
        filterGeneration += 1
        let generation = filterGeneration
        filterTask = Task.detached(priority: .userInitiated) { [weak self] in
            var out: [RecordRow] = []
            out.reserveCapacity(src.count)
            let needle = f.searchText.lowercased()
            for r in src {
                // 输入还在变化：尽早停下，列表由最新一代筛选任务负责
                if Task.isCancelled { return }
                if f.invalidOnly && !r.isInvalid { continue }
                if !f.types.isEmpty {
                    guard let t = r.type, f.types.contains(t) else { continue }
                }
                if !needle.isEmpty {
                    let hay = (r.preview + " " + r.typeLabel).lowercased()
                    if !hay.contains(needle) { continue }
                }
                out.append(r)
            }
            await self?.setVisible(out, generation: generation)
        }
    }

    private func setVisible(_ v: [RecordRow], generation: Int) {
        guard generation == filterGeneration else { return }
        visibleRows = v
    }
}
