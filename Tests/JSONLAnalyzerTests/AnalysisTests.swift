import XCTest
@testable import JSONLAnalyzer

private func parseLine(_ s: String, number: Int = 1, offset: UInt64 = 0) -> RecordRow {
    LineParser.parse(line: Array(s.utf8)[...], number: number, offset: offset)
}

final class AnalysisTests: XCTestCase {

    // MARK: LineParser

    func testTypeSeqTimeParsing() {
        let row = parseLine(#"{"type":"assistant/message","seq":23,"time":1794019306026,"data":{"turn":1}}"#)
        XCTAssertEqual(row.type, "assistant/message")
        XCTAssertEqual(row.seq, 23)
        XCTAssertEqual(row.time?.timeIntervalSince1970 ?? 0, 1_794_019_306.026, accuracy: 0.001)
        XCTAssertFalse(row.isInvalid)
    }

    func testRecordTypeFallback() {
        // Codex 格式：record_type，ISO8601 timestamp
        let row = parseLine(#"{"record_type":"state","timestamp":"2025-09-02T16:46:58.042Z"}"#)
        XCTAssertEqual(row.type, "state")
        XCTAssertEqual(row.time?.timeIntervalSince1970 ?? 0, 1_756_831_618.042, accuracy: 0.5)
    }

    func testCreatedAtSeconds() {
        let row = parseLine(#"{"createdAt":1700000000}"#)
        XCTAssertEqual(row.time?.timeIntervalSince1970, 1_700_000_000)
    }

    func testInvalidLine() {
        let row = parseLine(#"{"type":"broken""#)
        XCTAssertTrue(row.isInvalid)
        XCTAssertNotNil(row.invalidMessage)
    }

    func testBlankLine() {
        let row = parseLine("   ")
        XCTAssertTrue(row.isInvalid)
    }

    func testNonObjectRoot() {
        let row = parseLine(#"[1,2,3]"#)
        XCTAssertFalse(row.isInvalid)
        XCTAssertEqual(row.type, "(数组)")
    }

    // MARK: FieldAnalyzer

    func testFieldAggregation() {
        var fa = FieldAnalyzer()
        let obj = try! JSONSerialization.jsonObject(with: Data(
            #"{"a":1,"b":{"c":"x"},"arr":[{"d":true},{"d":false}],"s":[1,2,3]}"#.utf8))
        fa.accumulate(root: obj)
        XCTAssertEqual(fa.validLines, 1)

        let f = fa.fields["a"]
        XCTAssertEqual(f?.count, 1)
        XCTAssertEqual(f?.types, ["integer"])
        XCTAssertEqual(f?.example, "1")

        XCTAssertEqual(fa.fields["b.c"]?.types, ["string"])
        XCTAssertEqual(fa.fields["arr[*].d"]?.count, 2)
        XCTAssertEqual(fa.fields["arr[*].d"]?.types, ["boolean"])
        XCTAssertEqual(fa.fields["s[*]"]?.count, 3)
        XCTAssertEqual(fa.fields["s"]?.types, ["array"])
        // 覆盖率分母为有效行数
        XCTAssertEqual(fa.sortedByCount.first?.path, "s[*]")
    }

    // MARK: TokenScanner

    func testTokenScanDedupes() {
        let obj = try! JSONSerialization.jsonObject(with: Data(
            #"{"usage":{"inputTokens":100,"outputTokens":20},"stream":[{"chunk":{"usage":{"inputTokens":100,"outputTokens":20}}}]}"#.utf8))
        var found: [String: Double] = [:]
        TokenScanner.scan(obj, depth: 0, found: &found)
        // 同一记录里重复的 usage 只计一次
        XCTAssertEqual(found["输入"], 100)
        XCTAssertEqual(found["输出"], 20)
    }

    func testTokenScanPrefersRequestScopeOverCumulative() {
        // Codex token_usage_record：usage（单次）< turn_token_usage（轮累计）< thread_token_usage（线程累计）
        let obj = try! JSONSerialization.jsonObject(with: Data(
            #"{"payload":{"usage":{"input_tokens":133088,"cached_input_tokens":132864,"output_tokens":179},"turn_token_usage":{"input_tokens":133088,"output_tokens":179},"thread_token_usage":{"input_tokens":500022307,"output_tokens":1315316}}}"#.utf8))
        var found: [String: Double] = [:]
        TokenScanner.scan(obj, depth: 0, found: &found)
        XCTAssertEqual(found["输入"], 133088)
        XCTAssertEqual(found["缓存读"], 132864)
        XCTAssertEqual(found["输出"], 179)
    }

    func testTokenSnakeCase() {
        let obj = try! JSONSerialization.jsonObject(with: Data(
            #"{"info":{"input_tokens":7,"output_tokens":3,"cached_input_tokens":5}}"#.utf8))
        var found: [String: Double] = [:]
        TokenScanner.scan(obj, depth: 0, found: &found)
        XCTAssertEqual(found["输入"], 7)
        XCTAssertEqual(found["输出"], 3)
        XCTAssertEqual(found["缓存读"], 5)
    }

    // MARK: DurationAnalyzer

    func testDurationPairing() {
        let base = 1_000.0
        func row(_ type: String, _ t: Double, _ n: Int) -> RecordRow {
            RecordRow(id: n, offset: 0, length: 1, type: type, seq: nil,
                      time: Date(timeIntervalSince1970: base + t),
                      preview: "", isInvalid: false, invalidMessage: nil)
        }
        let rows = [
            row("turn/start", 0, 1),
            row("tool-call", 1, 2),
            row("turn/end", 5, 3),
            row("turn/start", 10, 4),
            row("turn/end", 12, 5),
        ]
        let durs = DurationAnalyzer.pair(rows)
        XCTAssertEqual(durs.count, 2)
        XCTAssertEqual(durs[0].seconds, 5, accuracy: 0.001)
        XCTAssertEqual(durs[0].prefix, "turn")
        XCTAssertEqual(durs[1].seconds, 2, accuracy: 0.001)
    }

    // MARK: TextExtractor

    func testTextExtractor() {
        let obj = try! JSONSerialization.jsonObject(with: Data(
            #"{"data":{"message":{"content":[{"type":"text","text":"你好，我是大肥鱼，初始化验证通过。"},{"type":"reasoning","text":""}],"role":"assistant"}},"id":"f577b28a-1892-4db3-908b-d5a310714ea6","long":"第一行\n第二行"}"#.utf8))
        let cands = TextExtractor.extract(root: obj)
        let paths = cands.map(\.path)
        // 短正文字段命中（text 叶子名），空字符串跳过
        XCTAssertTrue(paths.contains("data.message.content[0].text"))
        XCTAssertFalse(paths.contains("data.message.content[1].text"))
        // 含换行的字符串命中；UUID 不命中（无换行、长度不足且叶子名无暗示）
        XCTAssertTrue(paths.contains("long"))
        XCTAssertFalse(paths.contains("id"))
        // 按长度降序
        XCTAssertTrue(cands[0].length >= cands[cands.count - 1].length)
    }

    func testTextExtractorSortsByLength() {
        let obj = try! JSONSerialization.jsonObject(with: Data(
            ##"{"a":"短文本字段内容","body":"# 标题\n\n这是很长的一段正文内容，包含多个换行，理应排在第一位展示。"}"##.utf8))
        let cands = TextExtractor.extract(root: obj)
        XCTAssertEqual(cands.first?.path, "body")
    }

    func testTextExtractorExcludesStreamWordChunks() {
        // DSH 流式逐词分块：数组元素是短词，即使叶子名是 texts 也不应成为候选
        let obj = try! JSONSerialization.jsonObject(with: Data(
            #"{"stream":[{"texts":["你好","呀","\n","```","这是一段超过六十个字符门槛的数组元素长文本，用来验证流式分块里偶尔出现的整段内容仍然可以被抽取出来展示，而不是被当成碎片过滤掉。"]}],"message":{"text":"这段正文比较短但也应该被识别出来"}}"#.utf8))
        let cands = TextExtractor.extract(root: obj)
        let paths = cands.map(\.path)
        XCTAssertTrue(paths.contains("message.text"))
        XCTAssertTrue(cands.contains { $0.path.hasPrefix("stream[0].texts[") && $0.text.contains("整段内容") })
        XCTAssertFalse(paths.contains("stream[0].texts[0]"))
        // 含换行的空白碎片不是候选
        XCTAssertFalse(paths.contains { $0.hasSuffix("texts[2]") })
    }

    // MARK: TextRender / 搜索高亮

    func testUnescapeLiteralNewlines() {
        // 双重转义：字符串值里是字面 \n（JSON 源里写作 \\n）
        let (a, convertedA) = TextRender.unescapeLiteralIfNeeded("第一行\\n第二行\\n\\n第三行\\t缩进")
        XCTAssertTrue(convertedA)
        XCTAssertEqual(a, "第一行\n第二行\n\n第三行\t缩进")

        // 已有真实换行的不动（字面 \n 更可能是正文内容本身）
        let (b, convertedB) = TextRender.unescapeLiteralIfNeeded("真换行\n这里有字面 \\n 说明")
        XCTAssertFalse(convertedB)
        XCTAssertEqual(b, "真换行\n这里有字面 \\n 说明")

        // 无字面转义不动
        let (_, convertedC) = TextRender.unescapeLiteralIfNeeded("普通文本")
        XCTAssertFalse(convertedC)

        // 反斜杠本身保留
        let (d, _) = TextRender.unescapeLiteralIfNeeded("路径 C:\\dir\\n")
        XCTAssertEqual(d, "路径 C:\\dir\n")
    }

    func testRenderFallsBackGracefully() {
        // 正常 Markdown 渲染为 Markdown 模式
        let (attr, mode) = TextRender.render("# 标题\n\n- 项目\n\n正文 `code`")
        XCTAssertEqual(mode, "Markdown")
        XCTAssertGreaterThan(attr.length, 0)

        // 纯文本永远有兜底
        let (attr2, mode2) = TextRender.render("只是普通文本")
        XCTAssertGreaterThan(attr2.length, 0)
        XCTAssertFalse(mode2.isEmpty)
    }

    func testStripXmlWrapper() {
        // 同名首尾包裹标签剥离，内部 Markdown 才能正常渲染
        let inner = TextRender.stripXmlWrapper(
            "<system-reminder>\nA skill is reusable.\n\n- `a`: 用途一\n- `b`: 用途二\n</system-reminder>")
        XCTAssertTrue(inner.hasPrefix("A skill"))
        XCTAssertTrue(inner.hasSuffix("用途二"))
        // 标签不配对不剥离
        let keep = TextRender.stripXmlWrapper("<div>内容</span>")
        XCTAssertEqual(keep, "<div>内容</span>")
        // 无标签不动
        XCTAssertEqual(TextRender.stripXmlWrapper("普通文本"), "普通文本")
        // 只有标签没有内容时不动
        XCTAssertEqual(TextRender.stripXmlWrapper("<t></t>"), "<t></t>")
    }

    func testMatchRangesCaseInsensitive() {
        let s = "Use when 收发消息。use when 建群。USE WHEN"
        let ranges = HighlightedTextView.matchRanges(in: s, needle: "use when")
        XCTAssertEqual(ranges.count, 3)
        // 空搜索词返回空
        XCTAssertEqual(HighlightedTextView.matchRanges(in: s, needle: "").count, 0)
        // 无匹配
        XCTAssertEqual(HighlightedTextView.matchRanges(in: s, needle: "不存在").count, 0)
    }

    // MARK: MarkdownRenderer

    func testMarkdownHeadingFontAndListBullets() {
        let out = MarkdownRenderer.render("# 一级标题\n\n正文段落。\n\n- 项目一\n- 项目二\n\n1. 第一\n2. 第二")
        let s = out.string
        // 标题与列表标记都进入了文本
        XCTAssertTrue(s.contains("一级标题"))
        XCTAssertTrue(s.contains("•  项目一"))
        XCTAssertTrue(s.contains("1.  第一"))
        // 标题是粗体大字号
        let headingRange = (s as NSString).range(of: "一级标题")
        let font = out.attribute(.font, at: headingRange.location, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        if let f = font {
            XCTAssertTrue(f.pointSize >= 20, "标题字号应明显大于正文，实际 \(f.pointSize)")
            XCTAssertTrue(f.fontName.lowercased().contains("bold")
                          || f.fontName.lowercased().contains("heavy")
                          || NSFontManager.shared.weight(of: f) >= 9,
                          "标题应为粗体，实际 \(f.fontName)")
        }
        // 正文是常规字号
        let bodyRange = (s as NSString).range(of: "正文段落")
        let bodyFont = out.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(bodyFont?.pointSize ?? 0, 13, accuracy: 0.5)
    }

    func testMarkdownCodeBlockAndQuote() {
        let out = MarkdownRenderer.render("前置\n\n```swift\nlet a = 1\nlet b = 2\n```\n\n> 引用内容\n> 第二行")
        let s = out.string
        XCTAssertTrue(s.contains("swift"))
        XCTAssertTrue(s.contains("let a = 1"))
        XCTAssertTrue(s.contains("▎ 引用内容"))
        // 代码块有底色和等宽字体
        let codeRange = (s as NSString).range(of: "let a = 1")
        let font = out.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontName.contains("Mono") ?? font?.isFixedPitch ?? false)
        let bg = out.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil)
        XCTAssertNotNil(bg)
    }

    func testMarkdownInlineStyles() {
        let out = MarkdownRenderer.render("包含 **加粗**、`代码` 和普通文字")
        let s = out.string
        XCTAssertTrue(s.contains("加粗"))
        XCTAssertTrue(s.contains("代码"))
        let boldRange = (s as NSString).range(of: "加粗")
        let boldFont = out.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(boldFont?.fontName.lowercased().contains("bold") ?? false,
                      "加粗应为粗体字体，实际 \(boldFont?.fontName ?? "nil")")
        let codeRange = (s as NSString).range(of: "代码")
        let codeFont = out.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(codeFont?.isFixedPitch ?? false)
    }

    // MARK: JSON 折叠

    private func pretty(_ obj: String) -> String {
        let data = try! JSONSerialization.jsonObject(with: Data(obj.utf8))
        return String(data: try! JSONSerialization.data(withJSONObject: data,
                                                         options: [.prettyPrinted, .sortedKeys]),
                      encoding: .utf8)!
    }

    func testJsonFolderFolds() {
        let text = pretty(#"{"a":{"b":1,"c":[1,2]},"d":"}" ,"e":{},"f":[3]}"#)
        let folds = JsonFolder.folds(in: text)
        // 根对象、a、a.c、e、f 共 5 个可折叠块（Apple 的 pretty 格式连空容器也分行）
        XCTAssertEqual(folds.count, 5)
        let root = folds.first { $0.level == 0 }
        XCTAssertEqual(root?.openLine, 0)
        XCTAssertEqual(folds.first { $0.level == 1 }?.lineCount ?? 0, 5)
        // 字符串值里的 "}" 不会干扰配对
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[folds.first { $0.level == 0 }!.closeLine].trimmingCharacters(in: .whitespaces), "}")
    }

    func testJsonFoldRenderCollapsed() {
        let text = pretty(#"{"a":{"x":1,"y":{"z":2}},"b":[10,20]}"#)
        let folds = JsonFolder.folds(in: text)
        let aFold = folds.first { $0.level == 1 }!

        let rendered = JsonFoldRenderer.render(text, folds: folds, collapsed: [aFold.openLine])
        let lines = rendered.text.components(separatedBy: "\n")
        // 折叠块压缩成一行：opener + ⋯ N 行 + closer（含逗号）
        XCTAssertTrue(lines.contains { $0.contains("▸ \"a\" : { ⋯ 4 行 },") },
                      "实际内容：\(lines)")
        // 内部行不可见，其余行仍在
        XCTAssertFalse(rendered.text.contains("\"x\" : 1"))
        XCTAssertTrue(rendered.text.contains("\"b\" : ["))
        // 祖先折叠时嵌套块整体消失
        let rootFold = folds.first { $0.level == 0 }!
        let rootCollapsed = JsonFoldRenderer.render(text, folds: folds, collapsed: [rootFold.openLine])
        XCTAssertEqual(rootCollapsed.text, "▸ { ⋯ 10 行 }")

        // 展开状态：标记为 ▾ 在行首（缩进保留，所有标记对齐第 0 列），内容可见
        let expanded = JsonFoldRenderer.render(text, folds: folds, collapsed: [])
        let expLines = expanded.text.components(separatedBy: "\n")
        let origLines = text.components(separatedBy: "\n")
        XCTAssertEqual(expLines[1], JsonFoldRenderer.expandMark + " " + origLines[1])
        XCTAssertTrue(expanded.text.contains("x"))
        // 折叠行的 chevron 指回 openLine，且 range 确实落在 ▸ 上
        let chev = rendered.chevrons.first { $0.openLine == aFold.openLine }
        XCTAssertNotNil(chev)
        if let chev {
            let ns = rendered.text as NSString
            XCTAssertEqual(ns.substring(with: chev.range), "▸")
        }
    }

    func testEffectiveCollapsedExpandsMatchedBlocks() {
        let text = pretty(#"{"aaa":{"needle":1,"b":2},"ccc":{"d":3}}"#)
        let folds = JsonFolder.folds(in: text)
        let aaa = folds.first { $0.level == 1 }!
        let ccc = folds.last { $0.level == 1 }!

        // 全部折叠时，含匹配的 aaa 自动展开，ccc 保持折叠
        let effective = FoldableJsonTextView.effectiveCollapsed(
            [aaa.openLine, ccc.openLine], folds: folds, pretty: text, needle: "needle")
        XCTAssertFalse(effective.contains(aaa.openLine))
        XCTAssertTrue(effective.contains(ccc.openLine))

        // 搜索词不匹配任何内容时折叠状态原样保留
        let none = FoldableJsonTextView.effectiveCollapsed(
            [aaa.openLine], folds: folds, pretty: text, needle: "不存在的词")
        XCTAssertEqual(none, [aaa.openLine])

        // 空搜索词原样返回
        let empty = FoldableJsonTextView.effectiveCollapsed(
            [aaa.openLine, ccc.openLine], folds: folds, pretty: text, needle: "")
        XCTAssertEqual(empty, [aaa.openLine, ccc.openLine])
    }

    // MARK: SeqRefScanner

    func testSeqRefScannerPatterns() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(
            #"{"seq":123,"data":{"throughSeq":119,"messageSeqs":[120,121],"sourceEventSeqs":[100]}}"#.utf8))
            as! [String: Any]
        let refs = SeqRefScanner.scan(obj)
        // 根级 seq 是自身序号，不算引用
        XCTAssertFalse(refs.contains { $0.path == "seq" })
        XCTAssertEqual(refs.first { $0.path == "data.throughSeq" }?.seqs, [119])
        XCTAssertEqual(refs.first { $0.path == "data.messageSeqs" }?.seqs, [120, 121])
        XCTAssertEqual(refs.first { $0.path == "data.sourceEventSeqs" }?.seqs, [100])
    }

    func testSeqRefScannerRangePairs() throws {
        // seq_from/seq_to 同层配对展开为范围；跨度超限不展开
        let small = try JSONSerialization.jsonObject(with: Data(
            #"{"data":{"seq_from":10,"seq_to":13}}"#.utf8)) as! [String: Any]
        let smallRefs = SeqRefScanner.scan(small)
        XCTAssertEqual(smallRefs.count, 1)
        XCTAssertEqual(smallRefs[0].seqs, [10, 11, 12, 13])

        let big = try JSONSerialization.jsonObject(with: Data(
            #"{"data":{"event_seq_from":1,"event_seq_to":5000}}"#.utf8)) as! [String: Any]
        XCTAssertTrue(SeqRefScanner.scan(big).isEmpty, "跨度超过 1000 不展开")
    }

    func testSeqRefScannerNestedAndBooleanGuard() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(
            #"{"a":{"parent":{"refSeq":55,"ok":true}},"stream":[{"chunk":{"seq":77}}]}"#.utf8))
            as! [String: Any]
        let refs = SeqRefScanner.scan(obj)
        // 嵌套单值、数组元素里的 seq 都识别；布尔不当作数字
        XCTAssertEqual(refs.first { $0.path == "a.parent.refSeq" }?.seqs, [55])
        XCTAssertEqual(refs.first { $0.path.contains("chunk") }?.seqs, [77])
        XCTAssertFalse(refs.contains { $0.path.contains("ok") })
    }

    // MARK: Codex 专项处理

    func testTokenUsageRules() throws {
        // token_usage_record：只认 payload.usage
        let usageRow = try JSONSerialization.jsonObject(with: Data(
            #"{"type":"token_usage_record","payload":{"usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":30,"reasoning_output_tokens":10,"cache_write_input_tokens":0,"total_tokens":130},"turn_token_usage":{"input_tokens":200,"output_tokens":50},"thread_token_usage":{"input_tokens":900,"output_tokens":150}}}"#.utf8))
            as! [String: Any]
        let found = TokenUsageRules.normalize(TokenUsageRules.exactUsage(dict: usageRow))
        XCTAssertEqual(found["输入"], 100)
        XCTAssertEqual(found["缓存读"], 80)
        XCTAssertEqual(found["输出"], 30)
        // 混合总量 = (100-80) + 30 = 50
        let blended = TokenUsageRules.blendedTotal(input: found["输入"] ?? 0,
                                                   cached: found["缓存读"] ?? 0,
                                                   output: found["输出"] ?? 0)
        XCTAssertEqual(blended, 50)
        // 跳过规则
        XCTAssertTrue(TokenUsageRules.skipGenericScan(type: "token_usage_record", subtype: nil))
        XCTAssertTrue(TokenUsageRules.skipGenericScan(type: "event_msg", subtype: "token_count"))
        XCTAssertTrue(TokenUsageRules.skipGenericScan(type: "compacted", subtype: nil))
        XCTAssertFalse(TokenUsageRules.skipGenericScan(type: "response_item", subtype: "message"))
        XCTAssertFalse(TokenUsageRules.skipGenericScan(type: "assistant/message", subtype: nil))
    }

    func testCallRefScanner() throws {
        let call = try JSONSerialization.jsonObject(with: Data(
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{}","call_id":"call_1"}}"#.utf8))
            as! [String: Any]
        XCTAssertEqual(CallRefScanner.scan(dict: call),
                       CallRef(callId: "call_1", role: .call, variant: "function_call"))
        let output = try JSONSerialization.jsonObject(with: Data(
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"ok"}}"#.utf8))
            as! [String: Any]
        XCTAssertEqual(CallRefScanner.scan(dict: output)?.role, .output)
        // 类型族：local_shell_call 输出配 function_call_output
        XCTAssertEqual(CallRefScanner.family(for: "local_shell_call"), "fn")
        XCTAssertEqual(CallRefScanner.family(for: "function_call_output"), "fn")
        XCTAssertNil(CallRefScanner.family(for: "message"))
    }

    func testSubtypeAndOrdinalParsing() {
        let row = parseLine(#"{"timestamp":"2026-01-01T00:00:00.000Z","ordinal":42,"type":"response_item","payload":{"type":"function_call","name":"x"}}"#)
        XCTAssertEqual(row.type, "response_item")
        XCTAssertEqual(row.subtype, "function_call")
        XCTAssertEqual(row.typeLabel, "response_item·function_call")
        XCTAssertEqual(row.seq, 42)   // Codex ordinal 进序号列
    }

    // MARK: 会话还原

    private func dict(_ s: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
    }

    private func row(_ n: Int, _ type: String?, _ subtype: String? = nil) -> RecordRow {
        RecordRow(id: n, offset: 0, length: 1, type: type, subtype: subtype,
                  seq: nil, time: nil, preview: "", isInvalid: false, invalidMessage: nil)
    }

    func testConversationBuilderCodex() {
        let pairs: [(row: RecordRow, dict: [String: Any])] = [
            (row(1, "session_meta"), dict(#"{"type":"session_meta","payload":{"cwd":"/tmp/x","model":"gpt"}}"#)),
            (row(2, "response_item", "message"), dict(#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"帮我看看"}]}}"#)),
            (row(3, "response_item", "function_call"), dict(#"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"cmd\":\"ls\"}","call_id":"c1"}}"#)),
            (row(4, "response_item", "function_call_output"), dict(#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"file.txt"}}"#)),
            (row(5, "response_item", "message"), dict(#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"完成"}]}}"#)),
            (row(6, "event_msg", "token_count"), dict(#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":999}}}}"#)),
        ]
        let entries = ConversationBuilder.build(pairs)
        XCTAssertEqual(entries.count, 5)   // token_count 不进对话流
        XCTAssertEqual(entries[0].kind, .marker)
        XCTAssertEqual(entries[1].kind, .user)
        XCTAssertEqual(entries[1].body, "帮我看看")
        XCTAssertEqual(entries[2].kind, .toolCall)
        XCTAssertEqual(entries[2].meta, "c1")
        XCTAssertTrue(entries[2].body.contains("\"cmd\""))
        XCTAssertEqual(entries[3].kind, .toolOutput)
        XCTAssertEqual(entries[3].body, "file.txt")
        XCTAssertEqual(entries[4].kind, .assistant)
        XCTAssertEqual(entries[4].body, "完成")
    }

    func testConversationBuilderDSHAndClaude() {
        let pairs: [(row: RecordRow, dict: [String: Any])] = [
            (row(1, "user/message"), dict(#"{"type":"user/message","data":{"message":{"role":"user","content":[{"type":"text","text":"你好"}]}}}"#)),
            (row(2, "assistant/message"), dict(#"{"type":"assistant/message","data":{"message":{"role":"assistant","content":[{"type":"reasoning","text":"想想"},{"type":"text","text":"你好！"}]}}}"#)),
            (row(3, "user", nil), dict(#"{"type":"user","message":{"content":[{"type":"text","text":"claude 问题"},{"type":"tool_use","id":"tu1","name":"read","input":{"path":"/a"}}]}}"#)),
            (row(4, "assistant", nil), dict(#"{"type":"assistant","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"文件内容"},{"type":"text","text":"答案"}]}}"#)),
        ]
        let entries = ConversationBuilder.build(pairs)
        XCTAssertEqual(entries.count, 7)
        XCTAssertEqual(entries[0].kind, .user)
        XCTAssertEqual(entries[1].kind, .reasoning)
        XCTAssertEqual(entries[2].kind, .assistant)
        XCTAssertEqual(entries[3].kind, .user)             // claude 用户文本
        XCTAssertEqual(entries[4].kind, .toolCall)         // claude tool_use
        XCTAssertEqual(entries[4].meta, "tu1")
        XCTAssertTrue(entries[4].body.contains("/a"))
        XCTAssertEqual(entries[5].kind, .toolOutput)       // claude tool_result
        XCTAssertEqual(entries[5].body, "文件内容")
        XCTAssertEqual(entries[6].kind, .assistant)        // claude 回复文本
        XCTAssertEqual(entries[6].body, "答案")
    }

    // MARK: LineReader

    func testLineReaderOffsets() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ja-test-\(UUID().uuidString).jsonl")
        let lines = ["{\"a\":1}", "{\"b\":22}", "{\"c\":333}"]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let size = Int64((try tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
        let reader = LineReader(url: tmp, totalBytes: size)
        XCTAssertNotNil(reader)
        var got: [(String, UInt64)] = []
        while let (line, offset) = reader!.nextLine() {
            got.append((String(decoding: line, as: UTF8.self), offset))
        }
        XCTAssertEqual(got.map(\.0), lines)
        XCTAssertEqual(got[0].1, 0)
        XCTAssertEqual(got[1].1, 8)   // {"a":1}\n = 8 字节
        XCTAssertEqual(got[2].1, 17)
    }
}
