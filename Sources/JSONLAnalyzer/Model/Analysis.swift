import Foundation

// MARK: - 数据模型

/// 列表中的一行（每物理行一条，包括损坏行）。
struct RecordRow: Identifiable, Hashable {
    let id: Int          // 行号，1-based
    let offset: UInt64
    let length: Int
    var type: String?
    /// 次级类型：Codex 的 payload.type（如 event_msg 行的 token_count、response_item 行的 function_call）
    var subtype: String?
    /// 行级序号：DSH 为 seq，Codex 为 ordinal
    var seq: Int64?
    var time: Date?
    var preview: String
    var isInvalid: Bool
    var invalidMessage: String?

    var typeLabel: String {
        guard let t = type else { return isInvalid ? "损坏" : "—" }
        if let st = subtype, st != t { return t + "·" + st }
        return t
    }
}

/// 单文件的汇总统计。
struct OverviewStats {
    var totalLines = 0
    var validLines = 0
    var invalidLines = 0
    var maxLineLength = 0
    var typeCounts: [String: Int] = [:]
    var firstTime: Date?
    var lastTime: Date?
    /// 规范名（输入/输出/缓存读/缓存写/总量）→ 累计值
    var tokenTotals: [String: Double] = [:]

    var distinctTypes: Int { typeCounts.count }
}

/// 字段路径聚合结果。
struct FieldStats: Identifiable, Hashable {
    let path: String
    var count: Int
    var types: Set<String>
    var example: String

    var id: String { path }
    var typesLabel: String { types.sorted().joined(separator: "/") }
}

/// start/end 配对得到的区间时长。
struct DurationEntry: Identifiable, Hashable {
    let id: Int
    let prefix: String
    let start: Date
    let seconds: Double
}

/// 带 token 用量的时间点。
struct TokenPoint: Identifiable, Hashable {
    let id: Int
    let time: Date?
    let input: Double
    let output: Double
}

// MARK: - 单行解析（纯函数，便于测试）

enum LineParser {
    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 类型字段识别顺序：type → record_type → event
    static func typeValue(from dict: [String: Any]) -> String? {
        if let s = dict["type"] as? String, !s.isEmpty { return s }
        if let s = dict["record_type"] as? String, !s.isEmpty { return s }
        if let s = dict["event"] as? String, !s.isEmpty { return s }
        return nil
    }

    /// 时间字段识别：time / timestamp / ts / createdAt / created_at（毫秒、秒、ISO8601 自动判断）
    static func timeValue(from dict: [String: Any]) -> Date? {
        for key in ["time", "timestamp", "ts", "createdAt", "created_at"] {
            guard let v = dict[key] else { continue }
            if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                if let d = date(fromNumber: n.doubleValue) { return d }
            } else if let s = v as? String {
                if let d = isoFractional.date(from: s) ?? isoPlain.date(from: s) { return d }
            }
        }
        return nil
    }

    static func date(fromNumber v: Double) -> Date? {
        if v > 1e11 { return Date(timeIntervalSince1970: v / 1000) }  // 毫秒
        if v > 1e8 { return Date(timeIntervalSince1970: v) }          // 秒
        return nil
    }

    static func makePreview(_ line: ArraySlice<UInt8>) -> String {
        let limit = 160
        var s = String(decoding: line.prefix(limit), as: UTF8.self)
        if line.count > limit { s += "…" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// parseAndDecode 的结果。
    struct DecodedLine {
        let row: RecordRow
        /// 解析成功的 JSON 值（空行、损坏行为 nil）
        let object: Any?
        /// object 是字典时桥接好的根字典；调用方取 payload 等字段时直接复用，不必再桥接一次
        let root: [String: Any]?
    }

    /// 解析一行并一并返回解析出的对象。永不抛错：坏行返回 isInvalid = true、object = nil。
    /// 需要对象树的调用方（字段聚合、索引构建）必须复用这里的 object，不要再解析一遍。
    static func parseAndDecode(line: ArraySlice<UInt8>, number: Int, offset: UInt64) -> DecodedLine {
        let preview = makePreview(line)
        func row(type: String?, subtype: String? = nil, seq: Int64? = nil, time: Date? = nil,
                 invalid: Bool = false, message: String? = nil) -> RecordRow {
            RecordRow(id: number, offset: offset, length: line.count, type: type,
                      subtype: subtype, seq: seq, time: time, preview: preview,
                      isInvalid: invalid, invalidMessage: message)
        }

        if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
            return DecodedLine(row: row(type: nil, invalid: true, message: "空行"), object: nil, root: nil)
        }

        do {
            let obj = try JSONSerialization.jsonObject(with: Data(line), options: [.fragmentsAllowed])
            guard let dict = obj as? [String: Any] else {
                let kind: String
                if obj is [Any] { kind = "(数组)" } else { kind = "(标量)" }
                return DecodedLine(row: row(type: kind, time: nil), object: obj, root: nil)
            }
            // DSH 用 seq，Codex 用 ordinal（顶层可选）
            var seq = (dict["seq"] as? NSNumber)?.int64Value
            if seq == nil { seq = (dict["ordinal"] as? NSNumber)?.int64Value }
            // Codex：payload.type 作为次级类型
            var subtype: String?
            if let payload = dict["payload"] as? [String: Any],
               let pt = payload["type"] as? String, !pt.isEmpty {
                subtype = pt
            }
            return DecodedLine(
                row: row(type: typeValue(from: dict), subtype: subtype,
                         seq: seq, time: timeValue(from: dict)),
                object: obj, root: dict)
        } catch {
            let msg = error.localizedDescription.prefix(160).description
            return DecodedLine(row: row(type: nil, invalid: true, message: msg), object: nil, root: nil)
        }
    }

    /// 解析一行。永不抛错：坏行返回 isInvalid = true。
    static func parse(line: ArraySlice<UInt8>, number: Int, offset: UInt64) -> RecordRow {
        parseAndDecode(line: line, number: number, offset: offset).row
    }
}

// MARK: - 单次遍历扫描：字段路径聚合 + Token 用量 + sequence 引用

/// 一条出向引用：字段路径 + 引用的 seq 集合
struct SeqRef: Equatable {
    let path: String
    let seqs: [Int64]
}

/// 对一行的 JSON 对象树只遍历一次，同时完成三件事（各自可以单独开关）：
///
/// - **字段路径聚合**：递归聚合 key 路径。字典 `a.b.c`；数组元素合并到 `path[*]`
///   （对象元素继续下钻，标量元素按出现累计）。
/// - **Token 用量**：递归查找 token 叶子。同一条记录里同一规范名出现多次时取最小值：
///   DSH 会在 message.usage 和 stream[].chunk.usage 里重复同一份数据（相等，取谁都一样）；
///   Codex 的 token_usage_record 同时带单次 usage、轮累计 turn_token_usage、
///   线程累计 thread_token_usage，取最小即「单次请求」口径，避免把累计值重复累加。
/// - **sequence 引用**：字段名规范化（小写、去下划线）后按后缀识别——
///   恰为 `seq` 且在根层级的是自身序号，跳过；嵌套的 `seq` 视为引用；
///   后缀 `seq`（如 throughSeq）→ 单个数字引用；后缀 `seqs`（如 messageSeqs）→ 数字数组；
///   后缀 `seqfrom` / `seqto`（如 seq_from/seq_to）→ 同层配对展开为范围（跨度超过 1000 不展开，防爆炸）。
///
/// 为什么合成一次：`as? [String: Any]` 每转换一个容器，Foundation 都会新建一个 Swift 字典
/// 并桥接它全部的键。分成三个分析器各走一遍，等于每行把整棵树转换三遍。
///
/// 实例跨行复用：路径按字典树驻留、键名规范化结果有记忆，同一个键只在第一次遇到时计算。
final class LineScanner {
    /// 扫描结果
    struct Result {
        /// 根对象桥接后的字典（根不是字典时为 nil）；调用方取 payload 等字段直接用它，不必再桥接
        let root: [String: Any]?
        /// 规范名（输入/输出/缓存读/缓存写/总量）→ 用量
        var tokens: [String: Double] = [:]
        /// 出向 sequence 引用；同层之内范围对排在其它引用之前
        var refs: [SeqRef] = []
    }

    /// Token 字段的规范名映射（key 小写、去掉下划线）
    private static let canonical: [String: String] = [
        "inputtokens": "输入",
        "outputtokens": "输出",
        "cachereadtokens": "缓存读",
        "cachereadinputtokens": "缓存读",     // Claude: cache_read_input_tokens
        "cachedinputtokens": "缓存读",        // Codex: cached_input_tokens
        "cachedtokens": "缓存读",
        "cachewritetokens": "缓存写",
        "cachewriteinputtokens": "缓存写",
        "cachecreationinputtokens": "缓存写", // Claude: cache_creation_input_tokens
        "totaltokens": "总量",
    ]

    /// seq_from…seq_to 范围的最大跨度
    private static let maxRangeSpan: Int64 = 1000
    /// Token / sequence 扫描的嵌套深度上限
    private static let maxScanDepth = 10
    /// 值类型名，下标即类型编号
    private static let typeNames = ["null", "string", "integer", "number", "boolean", "array", "object", "other"]
    /// 键名记忆表的容量上限：以 id、时间戳等为键的对象不会把表撑大
    private static let memoLimit = 4096

    private let maxDepth: Int
    private let maxArraySample: Int

    // 字段统计：紧凑数组 + 类型位掩码，FieldStats 视图在读取时才生成
    private struct Stat { var count = 0; var types: UInt8 = 0; var example = "" }
    private var stats: [Stat] = []
    private var paths: [String] = []

    /// 路径字典树：每个不同的（父路径, 键）只建一个节点、只拼一次路径
    private final class Node {
        let path: String
        var stat: Int? = nil                 // 首次被记录时分配的 stats 下标
        var children: [String: Node]? = nil
        var star: Node? = nil                // 数组元素路径 path[*]
        init(_ path: String) { self.path = path }
    }
    private var root = Node("")
    private(set) var validLines = 0

    // 键名规范化记忆表；tokenMemo 用空串表示「不是 token 键」
    private var tokenMemo: [String: String] = [:]
    private var seqMemo: [String: String] = [:]

    init(maxDepth: Int = 8, maxArraySample: Int = 100) {
        self.maxDepth = maxDepth
        self.maxArraySample = maxArraySample
    }

    /// 扫描一个已桥接的字典根。返回根字典本身，方便调用方接着取字段。
    @discardableResult
    func scan(_ root: [String: Any], fields: Bool = false, tokens: Bool = false, seqs: Bool = false) -> Result {
        var res = Result(root: root)
        if fields { validLines += 1 }
        walkDict(root, node: self.root, depth: 0, fields: fields, tokens: tokens, seqs: seqs,
                 tokenOut: &res.tokens, refs: &res.refs)
        return res
    }

    /// 扫描任意根（字典、数组或标量）；根是字典时等同于 scan(_:fields:tokens:seqs:)。
    @discardableResult
    func scan(root obj: Any, fields: Bool = false, tokens: Bool = false, seqs: Bool = false) -> Result {
        if let dict = obj as? [String: Any] {
            return scan(dict, fields: fields, tokens: tokens, seqs: seqs)
        }
        var res = Result(root: nil)
        if fields { validLines += 1 }
        if let arr = obj as? [Any] {
            walkArr(arr, node: root, depth: 0, fields: fields, tokens: tokens, seqs: seqs,
                    tokenOut: &res.tokens, refs: &res.refs)
        }
        return res
    }

    /// 字段聚合结果，按出现次数降序、路径升序
    var sortedByCount: [FieldStats] {
        var out: [FieldStats] = []
        out.reserveCapacity(stats.count)
        for (i, s) in stats.enumerated() {
            var types = Set<String>()
            for b in 0..<Self.typeNames.count where s.types & (1 << UInt8(b)) != 0 {
                types.insert(Self.typeNames[b])
            }
            out.append(FieldStats(path: paths[i], count: s.count, types: types, example: s.example))
        }
        return out.sorted { $0.count != $1.count ? $0.count > $1.count : $0.path < $1.path }
    }

    /// 按路径取一条字段统计
    func field(_ path: String) -> FieldStats? {
        sortedByCount.first { $0.path == path }
    }

    // MARK: 遍历

    private func walkDict(_ d: [String: Any], node: Node, depth: Int,
                          fields: Bool, tokens: Bool, seqs: Bool,
                          tokenOut: inout [String: Double], refs: inout [SeqRef]) {
        // 字段聚合到 maxDepth 层为止，Token / sequence 扫描到 maxScanDepth 层为止
        let doFields = fields && depth < maxDepth
        let doTokens = tokens && depth <= Self.maxScanDepth
        let doSeqs = seqs && depth <= Self.maxScanDepth
        let isRoot = depth == 0
        var rangeFrom: Int64?
        var rangeTo: Int64?
        var rangeFromKey = ""
        // 本层的引用先缓冲：范围对要排在同层其它引用之前
        var local: [SeqRef] = []

        for (k, sub) in d {
            let kind = Self.kind(sub)
            // 路径树节点：字段聚合要用；sequence 引用在更深层也靠它拼路径。两者都不做时不必创建
            let child = (doFields || doSeqs) ? childNode(node, k) : node

            if doFields { record(child, sub, kind) }

            var tokensBelow = doTokens
            if doTokens, let canon = tokenCanon(k) {
                if let n = sub as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                    if let cur = tokenOut[canon] { tokenOut[canon] = Swift.min(cur, n.doubleValue) }
                    else { tokenOut[canon] = n.doubleValue }
                    tokensBelow = false            // 命中的 token 叶子不再下钻
                }
            }

            var seqsBelow = doSeqs
            if doSeqs {
                let n = seqNorm(k)
                if n.hasSuffix("seqfrom"), let v = Self.wholeNumber(sub) {
                    rangeFrom = v
                    rangeFromKey = Self.join(node.path, k)
                }
                if n.hasSuffix("seqto"), let v = Self.wholeNumber(sub) { rangeTo = v }
                if n == "seq" && isRoot {
                    seqsBelow = false                // 根级 seq 是自身序号
                } else if n.hasSuffix("seq") {
                    seqsBelow = false                // 单个数字引用
                    if let v = Self.wholeNumber(sub) {
                        local.append(SeqRef(path: Self.join(node.path, k), seqs: [v]))
                    }
                } else if n.hasSuffix("seqs"), kind == 5 {
                    seqsBelow = false                // 数字数组；值不是数组时照常下钻
                    let seqs = (sub as! [Any]).compactMap { Self.wholeNumber($0) }
                    if !seqs.isEmpty { local.append(SeqRef(path: Self.join(node.path, k), seqs: seqs)) }
                }
            }

            // 三件事都不需要下钻时连桥接都省掉（例如字段聚合到了深度上限之后）
            if doFields || tokensBelow || seqsBelow {
                if let dict = kind == 6 ? sub as? [String: Any] : nil {
                    walkDict(dict, node: child, depth: depth + 1, fields: doFields,
                             tokens: tokensBelow, seqs: seqsBelow, tokenOut: &tokenOut, refs: &local)
                } else if let arr = kind == 5 ? sub as? [Any] : nil {
                    walkArr(arr, node: child, depth: depth + 1, fields: doFields,
                            tokens: tokensBelow, seqs: seqsBelow, tokenOut: &tokenOut, refs: &local)
                }
            }
        }

        if let f = rangeFrom, let t = rangeTo, t >= f, t - f <= Self.maxRangeSpan {
            local.insert(SeqRef(path: rangeFromKey + "…to", seqs: Array(f...t)), at: 0)
        }
        refs.append(contentsOf: local)
    }

    private func walkArr(_ a: [Any], node: Node, depth: Int,
                         fields: Bool, tokens: Bool, seqs: Bool,
                         tokenOut: inout [String: Double], refs: inout [SeqRef]) {
        let doFields = fields && depth < maxDepth
        let doTokens = tokens && depth <= Self.maxScanDepth
        let doSeqs = seqs && depth <= Self.maxScanDepth
        // 数组元素的路径树节点：字段聚合同它记录 path[*]，sequence 引用靠它拼出 path[*].key
        let star = (doFields || doSeqs) ? starNode(node) : node
        // 字段聚合只采样前 maxArraySample 个元素；Token / sequence 扫描走全部元素
        let sampled = doFields ? min(a.count, maxArraySample) : 0
        if doFields {
            for i in 0..<sampled {
                let el = a[i]
                let kind = Self.kind(el)
                if kind != 5 && kind != 6 { record(star, el, kind) }    // 容器元素由下面的递归处理
            }
            if a.count > sampled, let i = star.stat {
                stats[i].example = "…另有 \(a.count - sampled) 个元素未采样"
            }
        }
        let limit = (doTokens || doSeqs) ? a.count : sampled
        for i in 0..<limit {
            let el = a[i]
            let kind = Self.kind(el)
            if let dict = kind == 6 ? el as? [String: Any] : nil {
                walkDict(dict, node: star, depth: depth + 1, fields: i < sampled,
                         tokens: doTokens, seqs: doSeqs, tokenOut: &tokenOut, refs: &refs)
            } else if let arr = kind == 5 ? el as? [Any] : nil {
                walkArr(arr, node: star, depth: depth + 1, fields: i < sampled,
                        tokens: doTokens, seqs: doSeqs, tokenOut: &tokenOut, refs: &refs)
            }
        }
    }

    // MARK: 字段统计与路径树

    @inline(__always) private func record(_ n: Node, _ v: Any, _ kind: UInt8) {
        let i: Int
        if let s = n.stat {
            i = s
        } else {
            stats.append(Stat())
            paths.append(n.path)
            i = stats.count - 1
            n.stat = i
        }
        stats[i].count += 1
        stats[i].types |= 1 << kind
        if stats[i].example.isEmpty { stats[i].example = Self.example(v, kind) }
    }

    @inline(__always) private func childNode(_ node: Node, _ k: String) -> Node {
        if let c = node.children?[k] { return c }
        let c = Node(Self.join(node.path, k))
        if node.children == nil { node.children = [:] }
        node.children![k] = c
        return c
    }

    @inline(__always) private func starNode(_ node: Node) -> Node {
        if let s = node.star { return s }
        let s = Node(node.path + "[*]")
        node.star = s
        return s
    }

    @inline(__always) private static func join(_ path: String, _ k: String) -> String {
        path.isEmpty ? k : path + "." + k
    }

    @inline(__always) private func tokenCanon(_ key: String) -> String? {
        if let memo = tokenMemo[key] { return memo.isEmpty ? nil : memo }
        let canon = Self.canonical[key.lowercased().replacingOccurrences(of: "_", with: "")]
        if tokenMemo.count < Self.memoLimit { tokenMemo[key] = canon ?? "" }
        return canon
    }

    @inline(__always) private func seqNorm(_ key: String) -> String {
        if let memo = seqMemo[key] { return memo }
        let norm = key.lowercased().replacingOccurrences(of: "_", with: "")
        if seqMemo.count < Self.memoLimit { seqMemo[key] = norm }
        return norm
    }

    /// 值的类型编号（typeNames 的下标），用 CFGetTypeID 判型。
    ///
    /// 不要写成 `v is NSNull` / `v is String`：从 `Any` 转到具体类型走的是运行时的慢路径
    /// （实测每次 200–400 ns，而这里每个节点都要调用），`is [String: Any]` 还会顺带把容器桥接一遍。
    /// CFGetTypeID 对任意对象都安全：NSNull 有独立编号，其余对象（URL、日期、纯 Swift 值）归入「其它」。
    @inline(__always) private static func kind(_ v: Any) -> UInt8 {
        switch CFGetTypeID(v as CFTypeRef) {
        case CFNullGetTypeID(): return 0
        case CFStringGetTypeID(): return 1
        case CFNumberGetTypeID():
            return (v as! NSNumber).doubleValue.truncatingRemainder(dividingBy: 1) == 0 ? 2 : 3
        case CFBooleanGetTypeID(): return 4
        case CFArrayGetTypeID(): return 5
        case CFDictionaryGetTypeID(): return 6
        default: return 7
        }
    }

    /// 整数值的 NSNumber（布尔不算）→ Int64；与行序号、seq 同口径
    private static func wholeNumber(_ v: Any) -> Int64? {
        guard CFGetTypeID(v as CFTypeRef) == CFNumberGetTypeID() else { return nil }
        return (v as! NSNumber).int64Value
    }

    private static func example(_ v: Any, _ kind: UInt8) -> String {
        switch kind {
        case 1:
            let s = v as! String
            return s.count > 60 ? String(s.prefix(60)) + "…" : s
        case 2, 3: return (v as! NSNumber).stringValue
        case 4: return (v as! NSNumber).boolValue ? "true" : "false"
        case 0: return "null"
        case 5: return "[]"
        case 6: return "{}"
        default: return ""
        }
    }
}

// MARK: - Token 用量口径（区分来源）

enum TokenUsageRules {
    /// 该行是否应跳过通用 token 扫描：
    /// - token_usage_record：由 exactUsage 精确提取（只认 payload.usage，
    ///   turn/thread 累计快照与求和重复）
    /// - event_msg·token_count：total_token_usage 是会话累计且可能被
    ///   context-window 估值覆盖，绝不能逐条求和
    /// - compacted：内嵌 latest_token_usage_record 是快照
    static func skipGenericScan(type: String?, subtype: String?) -> Bool {
        if type == "token_usage_record" { return true }
        if type == "compacted" { return true }
        if type == "event_msg", subtype == "token_count" { return true }
        return false
    }

    /// token_usage_record 行：只取 payload.usage。
    static func exactUsage(dict: [String: Any]) -> [String: Double] {
        guard let payload = dict["payload"] as? [String: Any],
              let usage = payload["usage"] as? [String: Any] else { return [:] }
        var found: [String: Double] = [:]
        for (k, v) in usage {
            if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                found[k] = n.doubleValue
            }
        }
        return found
    }

    /// 原始字段名 → 展示名（Codex 命名）
    static let codexFieldNames: [String: String] = [
        "input_tokens": "输入",
        "output_tokens": "输出",
        "cached_input_tokens": "缓存读",
        "cache_write_input_tokens": "缓存写",
        "reasoning_output_tokens": "推理",
        "total_tokens": "总量",
    ]

    /// 把 exactUsage 的原始字段名转成展示名（保持与通用扫描一致的键）。
    static func normalize(_ raw: [String: Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (k, v) in raw {
            out[codexFieldNames[k] ?? k] = v
        }
        return out
    }

    /// 官方混合总量（CLI codex exec 口径）：(input − cached) + output。
    /// input_tokens 已包含 cached，不能相加；reasoning 是 output 子集。
    static func blendedTotal(input: Double, cached: Double, output: Double) -> Double {
        (max(input - cached, 0)) + max(output, 0)
    }

    /// 展示口径自适应：
    /// - Codex/OpenAI：input 已含 cached → 净输入 = input − cached，混合 = 净输入 + output
    /// - Claude：input 不含 cached（cache_read 另列）→ 输入合计 = input + cached，混合 = 合计 + output
    /// 判别依据：cached ≤ input 视为包含式（一次请求的缓存命中不会超过其输入总量）。
    static func displaySums(input: Double, cached: Double, output: Double)
        -> (net: Double, blended: Double, inputIncludesCached: Bool) {
        if cached <= input && input > 0 {
            let net = max(input - cached, 0)
            return (net, net + max(output, 0), true)
        }
        return (input + cached, input + cached + max(output, 0), false)
    }
}

// MARK: - Codex call_id 配对

/// 一条工具调用/输出记录里的 call_id 信息
struct CallRef: Equatable {
    enum Role: Equatable {
        case call      // function_call / custom_tool_call / local_shell_call / tool_search_call
        case output    // *_output
    }
    let callId: String
    let role: Role
    /// payload.type 变体名（function_call 等），用于配对时的类型族校验
    let variant: String
}

enum CallRefScanner {
    /// 配对规则与 codex-rs core/src/tools/executed_tool_calls.rs 一致：
    /// FunctionCall|LocalShellCall → FunctionCallOutput；
    /// CustomToolCall → CustomToolCallOutput；ToolSearchCall → ToolSearchOutput。
    static func family(for variant: String) -> String? {
        switch variant {
        case "function_call", "local_shell_call": return "fn"
        case "function_call_output": return "fn"
        case "custom_tool_call": return "custom"
        case "custom_tool_call_output": return "custom"
        case "tool_search_call": return "search"
        case "tool_search_output": return "search"
        default: return nil
        }
    }

    /// 从 Codex response_item 行（payload 平铺 ResponseItem）提取 call_id。
    static func scan(dict: [String: Any]) -> CallRef? {
        guard let payload = dict["payload"] as? [String: Any],
              let variant = payload["type"] as? String,
              family(for: variant) != nil,
              let callId = payload["call_id"] as? String, !callId.isEmpty else { return nil }
        let role: CallRef.Role = variant.hasSuffix("_output") ? .output : .call
        return CallRef(callId: callId, role: role, variant: variant)
    }
}

// MARK: - start/end 时长配对

enum DurationAnalyzer {
    /// 把 `turn/start` 与 `turn/end` 这类同前缀事件按出现顺序配对。
    static func pair(_ rows: [RecordRow]) -> [DurationEntry] {
        var pending: [String: [Date]] = [:]
        var out: [DurationEntry] = []
        var idx = 0
        for r in rows {
            guard let t = r.type, let time = r.time else { continue }
            if t.hasSuffix("/start"), t.count > 6 {
                let pre = String(t.dropLast(6))
                pending[pre, default: []].append(time)
            } else if t.hasSuffix("/end"), t.count > 4 {
                let pre = String(t.dropLast(4))
                if let start = pending[pre]?.first {
                    pending[pre]?.removeFirst()
                    let sec = time.timeIntervalSince(start)
                    if sec >= 0, out.count < 2000 {
                        out.append(DurationEntry(id: idx, prefix: pre, start: start, seconds: sec))
                        idx += 1
                    }
                }
            }
        }
        return out
    }
}
