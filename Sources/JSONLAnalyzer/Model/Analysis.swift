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

    /// 解析一行。永不抛错：坏行返回 isInvalid = true。
    static func parse(line: ArraySlice<UInt8>, number: Int, offset: UInt64) -> RecordRow {
        let preview = makePreview(line)
        func row(type: String?, subtype: String? = nil, seq: Int64? = nil, time: Date? = nil,
                 invalid: Bool = false, message: String? = nil) -> RecordRow {
            RecordRow(id: number, offset: offset, length: line.count, type: type,
                      subtype: subtype, seq: seq, time: time, preview: preview,
                      isInvalid: invalid, invalidMessage: message)
        }

        if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
            return row(type: nil, invalid: true, message: "空行")
        }

        do {
            let obj = try JSONSerialization.jsonObject(with: Data(line), options: [.fragmentsAllowed])
            guard let dict = obj as? [String: Any] else {
                let kind: String
                if obj is [Any] { kind = "(数组)" } else { kind = "(标量)" }
                return row(type: kind, time: nil)
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
            return row(type: typeValue(from: dict), subtype: subtype,
                       seq: seq, time: timeValue(from: dict))
        } catch {
            let msg = error.localizedDescription.prefix(160).description
            return row(type: nil, invalid: true, message: msg)
        }
    }
}

// MARK: - 字段路径聚合

/// 递归聚合所有行里出现过的 key 路径。
/// - 字典：`a.b.c`
/// - 数组：元素合并到 `path[*]`（对象元素继续下钻，标量元素按出现累计）
struct FieldAnalyzer {
    private(set) var fields: [String: FieldStats] = [:]
    private(set) var validLines = 0
    private let maxDepth: Int
    private let maxArraySample: Int

    init(maxDepth: Int = 8, maxArraySample: Int = 100) {
        self.maxDepth = maxDepth
        self.maxArraySample = maxArraySample
    }

    mutating func accumulate(root: Any) {
        validLines += 1
        walk(root, path: "", depth: 0)
    }

    var sortedByCount: [FieldStats] {
        fields.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.path < $1.path }
    }

    private mutating func walk(_ v: Any, path: String, depth: Int) {
        if depth >= maxDepth { return }
        if let dict = v as? [String: Any] {
            for (k, sub) in dict {
                let p = path.isEmpty ? k : path + "." + k
                record(p, type: FieldAnalyzer.typeName(sub), value: sub)
                walk(sub, path: p, depth: depth + 1)
            }
        } else if let arr = v as? [Any] {
            let sampled = arr.prefix(maxArraySample)
            let rest = arr.count - sampled.count
            for el in sampled {
                if el is [String: Any] || el is [Any] {
                    walk(el, path: path + "[*]", depth: depth + 1)
                } else {
                    record(path + "[*]", type: FieldAnalyzer.typeName(el), value: el)
                }
            }
            if rest > 0 {
                if var f = fields[path + "[*]"] {
                    f.example = "…另有 \(rest) 个元素未采样"
                    fields[path + "[*]"] = f
                }
            }
        }
    }

    private mutating func record(_ path: String, type: String, value: Any) {
        var f = fields[path] ?? FieldStats(path: path, count: 0, types: [], example: "")
        f.count += 1
        f.types.insert(type)
        if f.example.isEmpty {
            switch value {
            case let s as String:
                f.example = s.count > 60 ? String(s.prefix(60)) + "…" : s
            case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID():
                f.example = n.stringValue
            case let b as Bool:
                f.example = b ? "true" : "false"
            case is NSNull:
                f.example = "null"
            case is [Any]:
                f.example = "[]"
            case is [String: Any]:
                f.example = "{}"
            default:
                break
            }
        }
        fields[path] = f
    }

    static func typeName(_ v: Any) -> String {
        switch v {
        case is NSNull: return "null"
        case is String: return "string"
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return "boolean" }
            return n.doubleValue.truncatingRemainder(dividingBy: 1) == 0 ? "integer" : "number"
        case is [Any]: return "array"
        case is [String: Any]: return "object"
        default: return "other"
        }
    }
}

// MARK: - Token 用量扫描

enum TokenScanner {
    /// 规范名映射（key 小写、去掉下划线）
    static let canonical: [String: String] = [
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

    /// 递归查找 token 用量叶子。同一条记录里同一规范名出现多次时取最小值：
    /// - DSH 会在 message.usage 和 stream[].chunk.usage 里重复同一份数据（相等，取谁都一样）
    /// - Codex 的 token_usage_record 同时带单次 usage、轮累计 turn_token_usage、
    ///   线程累计 thread_token_usage，取最小即"单次请求"口径，避免把累计值重复累加。
    static func scan(_ v: Any, depth: Int, found: inout [String: Double]) {
        if depth > 10 { return }
        if let dict = v as? [String: Any] {
            for (k, sub) in dict {
                let canon = canonical[k.replacingOccurrences(of: "_", with: "").lowercased()]
                if let canon,
                   let n = sub as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                    if let cur = found[canon] {
                        found[canon] = min(cur, n.doubleValue)
                    } else {
                        found[canon] = n.doubleValue
                    }
                } else {
                    scan(sub, depth: depth + 1, found: &found)
                }
            }
        } else if let arr = v as? [Any] {
            for el in arr { scan(el, depth: depth + 1, found: &found) }
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

// MARK: - DSH sequence 引用扫描

/// 一条出向引用：字段路径 + 引用的 seq 集合
struct SeqRef: Equatable {
    let path: String
    let seqs: [Int64]
}

/// 扫描 DSH 事件里的 sequence 引用。字段名规范化（小写、去下划线）后按后缀识别：
/// - 恰为 "seq" 且在根层级 → 自身序号，跳过；嵌套的 "seq" 视为引用
/// - 后缀 "seq"（如 throughSeq）→ 单个数字引用
/// - 后缀 "seqs"（如 messageSeqs / sourceEventSeqs）→ 数字数组
/// - 后缀 "seqfrom" / "seqto"（如 seq_from/seq_to、event_seq_from/event_seq_to）
///   → 同层配对展开为范围（跨度超过 1000 不展开，防爆炸）
enum SeqRefScanner {
    static let maxRangeSpan: Int64 = 1000

    static func normalized(_ key: String) -> String {
        key.lowercased().replacingOccurrences(of: "_", with: "")
    }

    static func isNumber(_ v: Any) -> Int64? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            return n.int64Value
        }
        return nil
    }

    static func scan(_ root: [String: Any]) -> [SeqRef] {
        var out: [SeqRef] = []
        walk(root, path: "", isRoot: true, depth: 0, out: &out)
        return out
    }

    private static func walk(_ v: Any, path: String, isRoot: Bool, depth: Int,
                             out: inout [SeqRef]) {
        guard depth <= 10 else { return }
        if let dict = v as? [String: Any] {
            // 先收集 from/to 范围对（同层配对，与遍历顺序无关）
            var rangeFrom: Int64?
            var rangeFromKey = ""
            var rangeTo: Int64?
            for (k, sub) in dict {
                let n = normalized(k)
                if n.hasSuffix("seqfrom"), let val = isNumber(sub) {
                    rangeFrom = val
                    rangeFromKey = path.isEmpty ? k : path + "." + k
                }
                if n.hasSuffix("seqto"), let val = isNumber(sub) {
                    rangeTo = val
                }
            }
            if let f = rangeFrom, let t = rangeTo, t >= f, t - f <= maxRangeSpan {
                out.append(SeqRef(path: rangeFromKey + "…to", seqs: Array(f...t)))
            }

            for (k, sub) in dict {
                let p = path.isEmpty ? k : path + "." + k
                let n = normalized(k)
                if n == "seq" && isRoot {
                    continue   // 根级 seq 是自身序号
                }
                if n.hasSuffix("seqs"), let arr = sub as? [Any] {
                    let seqs = arr.compactMap { isNumber($0) }
                    if !seqs.isEmpty { out.append(SeqRef(path: p, seqs: seqs)) }
                } else if n.hasSuffix("seq") || n == "seq" {
                    if let val = isNumber(sub) {
                        out.append(SeqRef(path: p, seqs: [val]))
                    }
                } else if sub is [String: Any] || sub is [Any] {
                    walk(sub, path: p, isRoot: false, depth: depth + 1, out: &out)
                }
            }
        } else if let arr = v as? [Any] {
            for el in arr {
                if el is [String: Any] || el is [Any] {
                    walk(el, path: path + "[*]", isRoot: false, depth: depth + 1, out: &out)
                }
            }
        }
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
