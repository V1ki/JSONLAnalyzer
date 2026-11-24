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

    func testParseAndDecodeReturnsObjectAndRoot() {
        let dict = LineParser.parseAndDecode(line: Array(#"{"type":"a","seq":3}"#.utf8)[...], number: 1, offset: 0)
        XCTAssertEqual(dict.row.type, "a")
        XCTAssertEqual((dict.object as? [String: Any])?["seq"] as? Int, 3)
        XCTAssertEqual(dict.root?["type"] as? String, "a")

        // JSON Lines 允许一行就是一个值：标量根是有效行，与列表里的显示一致
        let scalar = LineParser.parseAndDecode(line: Array("123".utf8)[...], number: 2, offset: 0)
        XCTAssertFalse(scalar.row.isInvalid)
        XCTAssertEqual(scalar.row.type, "(标量)")
        XCTAssertEqual(scalar.object as? Int, 123)
        XCTAssertNil(scalar.root)

        let broken = LineParser.parseAndDecode(line: Array(#"{"a":"#.utf8)[...], number: 3, offset: 0)
        XCTAssertTrue(broken.row.isInvalid)
        XCTAssertNil(broken.object)
    }

    // MARK: LineScanner 字段聚合

    func testFieldAggregation() throws {
        let scanner = LineScanner()
        let obj = try JSONSerialization.jsonObject(with: Data(
            #"{"a":1,"b":{"c":"x"},"arr":[{"d":true},{"d":false}],"s":[1,2,3]}"#.utf8))
        scanner.scan(root: obj, fields: true)
        XCTAssertEqual(scanner.validLines, 1)

        let f = scanner.field("a")
        XCTAssertEqual(f?.count, 1)
        XCTAssertEqual(f?.types, ["integer"])
        XCTAssertEqual(f?.example, "1")

        XCTAssertEqual(scanner.field("b.c")?.types, ["string"])
        XCTAssertEqual(scanner.field("arr[*].d")?.count, 2)
        XCTAssertEqual(scanner.field("arr[*].d")?.types, ["boolean"])
        XCTAssertEqual(scanner.field("s[*]")?.count, 3)
        XCTAssertEqual(scanner.field("s")?.types, ["array"])
        // 覆盖率分母为有效行数
        XCTAssertEqual(scanner.sortedByCount.first?.path, "s[*]")
    }

    func testFieldValueTypesAndExamples() throws {
        let scanner = LineScanner()
        let obj = try JSONSerialization.jsonObject(with: Data(
            #"{"i":1e3,"n":2.5,"neg":-0,"big":12345678901234567890,"b":false,"z":null,"o":{},"a":[],"s":"x"}"#.utf8))
        scanner.scan(root: obj, fields: true)
        XCTAssertEqual(scanner.field("i")?.typesLabel, "integer")
        XCTAssertEqual(scanner.field("i")?.example, "1000")
        XCTAssertEqual(scanner.field("n")?.typesLabel, "number")
        XCTAssertEqual(scanner.field("neg")?.typesLabel, "integer")
        XCTAssertEqual(scanner.field("b")?.typesLabel, "boolean")
        XCTAssertEqual(scanner.field("b")?.example, "false")
        XCTAssertEqual(scanner.field("z")?.example, "null")
        XCTAssertEqual(scanner.field("o")?.example, "{}")
        XCTAssertEqual(scanner.field("a")?.example, "[]")
        // 同一路径在不同行里类型不同：类型集合累加，示例值取第一次遇到的
        scanner.scan(root: try JSONSerialization.jsonObject(with: Data(#"{"s":7}"#.utf8)), fields: true)
        XCTAssertEqual(scanner.field("s")?.typesLabel, "integer/string")
        XCTAssertEqual(scanner.field("s")?.example, "x")
        XCTAssertEqual(scanner.validLines, 2)
    }

    func testFieldDepthLimitAndArraySampling() throws {
        // 逐层包裹：l1 → l12，键 v<n> 位于第 n 层。字段聚合到第 8 层为止
        var deep = #"{"v":1}"#
        for level in stride(from: 12, through: 1, by: -1) {
            deep = "{\"l\(level)\":\(deep),\"v\(level)\":1}"
        }
        func path(_ level: Int) -> String { (1..<level).map { "l\($0)" }.joined(separator: ".") + ".v\(level)" }
        // 数组：只采样前 100 个元素，其余只在标量元素的示例里提示
        let dicts = (0..<150).map { "{\"k\":\($0)}" }.joined(separator: ",")
        let scalars = (0..<150).map(String.init).joined(separator: ",")
        let json = "{" + deep.dropFirst().dropLast() + ",\"arr\":[\(dicts)],\"s\":[\(scalars)]}"
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let scanner = LineScanner()
        scanner.scan(root: obj, fields: true)

        XCTAssertNotNil(scanner.field("v1"))
        XCTAssertNotNil(scanner.field(path(8)))     // 第 8 层的键仍被记录
        XCTAssertNil(scanner.field(path(9)))        // 再深不再下钻
        XCTAssertEqual(scanner.field("arr[*].k")?.count, 100)
        XCTAssertEqual(scanner.field("arr[*].k")?.example, "0")
        XCTAssertEqual(scanner.field("s[*]")?.count, 100)
        XCTAssertEqual(scanner.field("s[*]")?.example, "…另有 50 个元素未采样")
    }

    // MARK: LineScanner Token 用量

    func testTokenScanDedupes() {
        let obj = try! JSONSerialization.jsonObject(with: Data(
            #"{"usage":{"inputTokens":100,"outputTokens":20},"stream":[{"chunk":{"usage":{"inputTokens":100,"outputTokens":20}}}]}"#.utf8))
        let found = LineScanner().scan(root: obj, tokens: true).tokens
        // 同一记录里重复的 usage 只计一次
        XCTAssertEqual(found["输入"], 100)
        XCTAssertEqual(found["输出"], 20)
    }

    func testTokenScanPrefersRequestScopeOverCumulative() {
        // Codex token_usage_record：usage（单次）< turn_token_usage（轮累计）< thread_token_usage（线程累计）
        let obj = try! JSONSerialization.jsonObject(with: Data(
            #"{"payload":{"usage":{"input_tokens":133088,"cached_input_tokens":132864,"output_tokens":179},"turn_token_usage":{"input_tokens":133088,"output_tokens":179},"thread_token_usage":{"input_tokens":500022307,"output_tokens":1315316}}}"#.utf8))
        let found = LineScanner().scan(root: obj, tokens: true).tokens
        XCTAssertEqual(found["输入"], 133088)
        XCTAssertEqual(found["缓存读"], 132864)
        XCTAssertEqual(found["输出"], 179)
    }

    func testTokenSnakeCase() {
        let obj = try! JSONSerialization.jsonObject(with: Data(
            #"{"info":{"input_tokens":7,"output_tokens":3,"cached_input_tokens":5}}"#.utf8))
        let found = LineScanner().scan(root: obj, tokens: true).tokens
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

    // MARK: LineScanner sequence 引用

    func testSeqRefScannerPatterns() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(
            #"{"seq":123,"data":{"throughSeq":119,"messageSeqs":[120,121],"sourceEventSeqs":[100]}}"#.utf8))
            as! [String: Any]
        let refs = LineScanner().scan(obj, seqs: true).refs
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
        let smallRefs = LineScanner().scan(small, seqs: true).refs
        XCTAssertEqual(smallRefs.count, 1)
        XCTAssertEqual(smallRefs[0].seqs, [10, 11, 12, 13])

        let big = try JSONSerialization.jsonObject(with: Data(
            #"{"data":{"event_seq_from":1,"event_seq_to":5000}}"#.utf8)) as! [String: Any]
        XCTAssertTrue(LineScanner().scan(big, seqs: true).refs.isEmpty, "跨度超过 1000 不展开")
    }

    func testSeqRefScannerNestedAndBooleanGuard() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(
            #"{"a":{"parent":{"refSeq":55,"ok":true}},"stream":[{"chunk":{"seq":77}}]}"#.utf8))
            as! [String: Any]
        let refs = LineScanner().scan(obj, seqs: true).refs
        // 嵌套单值、数组元素里的 seq 都识别；布尔不当作数字
        XCTAssertEqual(refs.first { $0.path == "a.parent.refSeq" }?.seqs, [55])
        XCTAssertEqual(refs.first { $0.path.contains("chunk") }?.seqs, [77])
        XCTAssertFalse(refs.contains { $0.path.contains("ok") })
    }

    // MARK: LineScanner：合并遍历

    private func json(_ text: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    func testSeqRefUnderSeqsKeyDependsOnValueType() throws {
        // 键以 seqs 结尾时：值是数组 → 只收其中的数字、不下钻；值是字典 → 照常下钻找嵌套引用。
        // 以 seq 结尾的键则一律当作引用：值不是数字就什么都不做，也不下钻
        let obj = try json(#"{"seq":1,"data":{"dictSeqs":{"innerSeq":85,"deep":[{"nestedSeq":86}]},"arrSeqs":[{"innerSeq":87},88],"numSeqs":89,"seq":{"zSeq":4}}}"#)
        let refs = LineScanner().scan(obj, seqs: true).refs
        // 字典遍历顺序不定，按路径比较
        let byPath = Dictionary(refs.map { ($0.path, $0.seqs) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byPath["data.dictSeqs.innerSeq"], [85])
        XCTAssertEqual(byPath["data.dictSeqs.deep[*].nestedSeq"], [86])
        XCTAssertEqual(byPath["data.arrSeqs"], [88])            // 数组元素里的字典不下钻
        XCTAssertNil(byPath["data.numSeqs"])                     // 数字不是数组，不构成引用
        XCTAssertNil(byPath["data.seq.zSeq"])                      // 非根层的 seq 键也不下钻
        XCTAssertEqual(byPath.count, 3)
    }

    func testSeqRefRangePairComesFirstAndRootSeqIsSkipped() throws {
        let obj = try json(#"{"seq":5,"data":{"bSeq":2,"x_seq_from":10,"x_seq_to":12,"nested":{"ySeq":3},"seq":4}}"#)
        let refs = LineScanner().scan(obj, seqs: true).refs
        XCTAssertEqual(refs.first?.path, "data.x_seq_from…to")
        XCTAssertEqual(refs.first?.seqs, [10, 11, 12])
        XCTAssertEqual(Set(refs.map(\.path)), ["data.x_seq_from…to", "data.bSeq", "data.nested.ySeq", "data.seq"])
        XCTAssertEqual(refs.count, 4)
    }

    func testCombinedScanMatchesSeparateScans() throws {
        // 一行里同时有字段、token、seq 引用：合并成一次遍历的结果必须与分开扫描一致
        var deep = #"{"input_tokens":5}"#
        for level in 1...13 { deep = "{\"l\(level)\":\(deep)}" }      // 超过 Token 扫描深度上限
        let text = #"{"type":"assistant/message","seq":7,"time":1700000000000,"throughSeq":[1,2],"data":{"message":{"role":"assistant","content":[{"type":"text","text":"hi"},{"type":"tool-call","id":"c1","arguments":{"cmd":"ls"}}]},"usage":{"inputTokens":100,"outputTokens":20}},"stream":[{"chunk":{"usage":{"inputTokens":90}},"refSeq":8}],"tokens":{"input_tokens":true,"deep":\#(deep)}}"#
        let obj = try json(text)

        // 字段统计累积在扫描器实例上，所以用两个实例分别做合并扫描与单独扫描
        let all = LineScanner()
        let combined = all.scan(obj, fields: true, tokens: true, seqs: true)
        let fieldsScanner = LineScanner()
        let onlyFields = fieldsScanner.scan(obj, fields: true)
        let onlyTokens = LineScanner().scan(obj, tokens: true).tokens
        let onlyRefs = LineScanner().scan(obj, seqs: true).refs

        XCTAssertEqual(combined.tokens, onlyTokens)
        XCTAssertEqual(combined.refs, onlyRefs)
        XCTAssertEqual(all.sortedByCount.map(\.path), fieldsScanner.sortedByCount.map(\.path))
        XCTAssertEqual(all.sortedByCount.map(\.count), fieldsScanner.sortedByCount.map(\.count))
        XCTAssertEqual(all.sortedByCount.map(\.typesLabel), fieldsScanner.sortedByCount.map(\.typesLabel))
        XCTAssertEqual(combined.root?["type"] as? String, "assistant/message")
        XCTAssertEqual(onlyFields.root?["seq"] as? Int, 7)       // 只开 fields 时同样带回根字典
        // token 取最小值；嵌套过深（第 14 层）的那个不计
        XCTAssertEqual(onlyTokens["输入"], 90)
        XCTAssertEqual(onlyTokens["输出"], 20)
        XCTAssertEqual(Set(onlyRefs.map(\.path)), ["stream[*].refSeq"])
        XCTAssertEqual(all.field("data.message.content[*].type")?.typesLabel, "string")
        XCTAssertEqual(all.field("throughSeq")?.typesLabel, "array")
        XCTAssertEqual(all.validLines, 1)
    }

    func testTokenScanDepthLimit() throws {
        func nested(_ depth: Int) throws -> [String: Any] {
            var inner = #"{"input_tokens":5}"#
            for level in 1...depth { inner = "{\"l\(level)\":\(inner)}" }
            return try json(inner)
        }
        // nested(_:) 包 wrap 层后 token 键位于第 wrap + 1 层（根的子键是第 1 层）：
        // 第 11 层仍计入，第 12 层不计
        XCTAssertEqual(LineScanner().scan(root: try nested(10), tokens: true).tokens["输入"], 5)
        XCTAssertNil(LineScanner().scan(root: try nested(11), tokens: true).tokens["输入"])
    }

    func testScannerStillWorksPastMemoCap() throws {
        // 超过记忆表上限后只是不再缓存，识别结果不变
        let scanner = LineScanner()
        let many = (0..<5000).map { "\"k\($0)\":\($0)" }.joined(separator: ",")
        for round in 0..<2 {
            let obj = try json("{\"m\":{\(many)},\"usage\":{\"input_tokens\":\(round + 1)},\"refSeq\":9}")
            let r = scanner.scan(obj, fields: true, tokens: true, seqs: true)
            XCTAssertEqual(r.tokens["输入"], Double(round + 1))
            XCTAssertEqual(r.refs.map(\.path), ["refSeq"])
        }
        XCTAssertEqual(scanner.field("m.k4999")?.example, "4999")
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

    // MARK: 会话还原：流式构建与截断

    private func chatLines() -> [String] {
        [
            #"{"type":"session_meta","payload":{"cwd":"/tmp/x","model":"gpt"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"帮我看看"}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"cmd\":\"ls\"}","call_id":"c1"}}"#,
            #"{"type":"user/message","data":{"message":{"role":"user","content":[{"type":"text","text":"你好"}]}}}"#,
            #"{"type":"broken"#,
            "   ",
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"答案"}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_use","id":"tu1","name":"read","input":{"path":"/a"}}]}}"#,
        ]
    }

    private func chatRow(_ n: Int, _ type: String?) -> RecordRow {
        RecordRow(id: n, offset: 0, length: 1, type: type, subtype: nil, seq: nil,
                  time: nil, preview: "", isInvalid: false, invalidMessage: nil)
    }

    func testBuildStreamingMatchesBatchBuild() throws {
        let url = try writeTemp(chatLines())
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try JsonlFile.prepare(url)
        var pairs: [(row: RecordRow, dict: [String: Any])] = []
        var allRows: [RecordRow] = []
        let reader = try XCTUnwrap(file.openReader())
        var n = 0
        while let (line, offset) = reader.nextLine() {
            n += 1
            let decoded = LineParser.parseAndDecode(line: line, number: n, offset: offset)
            allRows.append(decoded.row)
            if let dict = decoded.root { pairs.append((decoded.row, dict)) }
        }
        func key(_ e: ChatEntry) -> String {
            "\(e.id)|\(e.kind)|\(e.lineNo)|\(e.time.map { "\($0)" } ?? "-")|\(e.title ?? "-")|\(e.body)|\(e.meta ?? "-")"
        }
        let batch = ConversationBuilder.build(pairs)
        let streamed = try XCTUnwrap(ConversationBuilder.buildStreaming(file, rows: allRows))
        XCTAssertEqual(batch.count, 6)     // 坏行与空行不进对话流
        XCTAssertEqual(streamed.count, batch.count)
        XCTAssertEqual(streamed.map(key), batch.map(key))

        // 文件已经不在了：得到空结果，而不是崩溃
        try FileManager.default.removeItem(at: file.dataURL)
        XCTAssertEqual(ConversationBuilder.buildStreaming(file, rows: allRows)?.count, 0)
    }

    func testBuildIdBaseContinuesNumbering() {
        let dict: [String: Any] = ["type": "user", "message": ["content": [["type": "text", "text": "a"],
                                                                            ["type": "text", "text": "b"]]]]
        let first = ConversationBuilder.build([(chatRow(1, "user"), dict)])
        XCTAssertEqual(first.map(\.id), [0, 1])
        let next = ConversationBuilder.build([(chatRow(2, "user"), dict)], idBase: first.count)
        XCTAssertEqual(next.map(\.id), [2, 3])
    }

    func testConversationBodyTruncationCountsCharacters() {
        func body(_ text: String) -> String {
            let dict: [String: Any] = ["type": "user", "message": ["content": [["type": "text", "text": text]]]]
            return ConversationBuilder.build([(chatRow(1, "user"), dict)])[0].body
        }
        let limit = ConversationBuilder.bodyLimit
        // 按字符数判断：39,999 个汉字有近 12 万字节，字节数早就超了，但不应截断
        let cjk = body(String(repeating: "中", count: limit - 1))
        XCTAssertEqual(cjk.count, limit - 1)
        XCTAssertFalse(cjk.hasSuffix("（已截断）"))
        // 超过 40,000 个字符才截断，并带提示
        let mark = "\n…（已截断）"
        let long = body(String(repeating: "中", count: limit + 500))
        XCTAssertTrue(long.hasSuffix(mark))
        XCTAssertEqual(long.count, limit + mark.count)
        XCTAssertEqual(body("短文本"), "短文本")
    }

    // MARK: 文本页缓存

    func testTextTabCacheReadsAndRendersOnce() throws {
        let short = "这是一段短文本内容"                                        // 字段名 text，≥ 8 字符
        let long = String(repeating: "长", count: TextTabCache.syncRenderLimit + 100)
        let filler = String(repeating: " ", count: TextTabCache.syncReadLimit + 1000)   // 把第 2 行撑过同步读取上限
        let url = try writeTemp([
            #"{"type":"a","text":"\#(short)","body":"\#(long)"}"#,
            #"{"type":"b","text":"\#(short)","pad":"\#(filler)"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try JsonlFile.prepare(url)
        let reader = try XCTUnwrap(file.openReader())
        var rows: [RecordRow] = []
        while let (line, offset) = reader.nextLine() {
            rows.append(LineParser.parseAndDecode(line: line, number: rows.count + 1, offset: offset).row)
        }
        XCTAssertEqual(rows.count, 2)
        let cache = TextTabCache()

        // 小行：同步读出；大行：同步读取返回 nil，等后台结果存进来
        let small = try XCTUnwrap(cache.candidates(for: rows[0], file: file))
        XCTAssertEqual(Set(small.map(\.path)), ["text", "body"])
        XCTAssertNil(cache.candidates(for: rows[1], file: file))
        cache.setCandidates([TextCandidate(path: "text", text: short)], for: rows[1].id)
        XCTAssertEqual(cache.candidates(for: rows[1], file: file)?.map(\.path), ["text"])

        // 短文本同步渲染；长文本等后台渲染结果
        let shortCand = try XCTUnwrap(small.first { $0.path == "text" })
        let longCand = try XCTUnwrap(small.first { $0.path == "body" })
        XCTAssertNotNil(cache.rendered(shortCand, for: rows[0]))
        XCTAssertNil(cache.rendered(longCand, for: rows[0]))
        cache.setRendered(TextRender.prepare(longCand, limit: TextTabCache.renderLimit), for: rows[0])
        XCTAssertNotNil(cache.rendered(longCand, for: rows[0]))

        // 文件删了也还能取到：说明后续读取走的是缓存，没有再读文件
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(cache.candidates(for: rows[0], file: file)?.count, 2)
        XCTAssertNotNil(cache.rendered(shortCand, for: rows[0]))

        // 重新加载（代数变化）后缓存失效：文件已不存在，读出来是空；同一个代数不清缓存
        cache.sync(token: 1)
        XCTAssertEqual(cache.candidates(for: rows[0], file: file)?.count, 0)
        cache.setCandidates([TextCandidate(path: "x", text: short)], for: rows[0].id)
        cache.sync(token: 1)
        XCTAssertEqual(cache.candidates(for: rows[0], file: file)?.count, 1)
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

    func testLineReaderMatchesReferenceOnMixedContent() throws {
        // 确定性伪随机内容：空行、短行、跨越多个 64KB 块的长行，以及末尾不带换行的最后一行
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        // 最高位置 1，保证生成的字节不会与换行符混淆
        func body(_ upper: UInt64) -> [UInt8] {
            (0..<Int(next() % upper)).map { _ in UInt8(truncatingIfNeeded: next() | 0x80) }
        }
        var expected: [(offset: Int, length: Int)] = []
        var bytes: [UInt8] = []
        func appendLine(_ b: [UInt8]) {
            expected.append((bytes.count, b.count))
            bytes.append(contentsOf: b)
            bytes.append(0x0A)
        }
        for _ in 0..<700 {
            switch next() % 10 {
            case 0: appendLine([])
            case 1...6: appendLine(body(300))
            default: appendLine(body(300_000))
            }
        }
        let last = body(100_000)
        expected.append((bytes.count, last.count))   // 末行不带换行
        bytes.append(contentsOf: last)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ja-reader-\(UUID().uuidString).bin")
        try Data(bytes).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let reader = try XCTUnwrap(LineReader(url: tmp, totalBytes: Int64(bytes.count)))
        var got: [(offset: UInt64, length: Int, same: Bool)] = []
        while let (line, offset) = reader.nextLine() {
            let e = expected[got.count]
            got.append((offset, line.count, Array(line) == Array(bytes[e.offset..<(e.offset + e.length)])))
        }
        XCTAssertEqual(got.count, expected.count)
        XCTAssertEqual(got.map(\.offset), expected.map { UInt64($0.offset) })
        XCTAssertEqual(got.map(\.length), expected.map(\.length))
        XCTAssertTrue(got.allSatisfy(\.same))
        XCTAssertNil(reader.nextLine())
        XCTAssertEqual(reader.consumedBytes, Int64(bytes.count))
    }

    func testLineReaderKeepsEarlierLinesValid() throws {
        // 已取出的行留到后续读取之后仍然有效：缓冲区扩充或前移不能改写它
        var lines = (0..<3000).map { #"{"seq":\#($0),"text":"\#(String(repeating: "x", count: 60))"}"# }
        lines[1500] = #"{"seq":1500,"text":"\#(String(repeating: "y", count: 200_000))"}"#
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ja-reader-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let reader = try XCTUnwrap(LineReader(url: tmp, totalBytes: Int64((try tmp.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)))
        var kept: [ArraySlice<UInt8>] = []
        var copies: [String] = []
        while let (line, _) = reader.nextLine() {
            kept.append(line)
            copies.append(String(decoding: line, as: UTF8.self))
        }
        XCTAssertEqual(kept.count, lines.count)
        for (slice, copy) in zip(kept, copies) {
            XCTAssertEqual(String(decoding: slice, as: UTF8.self), copy)
        }
    }

    // MARK: 回归：切换文件后，旧筛选任务迟到的结果覆盖列表

    private func writeTemp(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ja-test-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)
        return url
    }

    @MainActor
    private func waitUntilLoaded(_ store: RecordStore) async {
        let deadline = Date().addingTimeInterval(20)
        while case .loading = store.state, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    @MainActor
    func testStaleFilterDoesNotOverwriteNewFile() async throws {
        // 4 万行的文件上发起一次较慢的筛选，立刻切到 50 行的小文件
        let big = try JsonlFile.prepare(writeTemp((0..<40_000).map {
            #"{"type":"row-\#($0 % 7)","seq":\#($0),"text":"preview text number \#($0)"}"#
        }))
        let small = try JsonlFile.prepare(writeTemp((0..<50).map {
            #"{"type":"small-\#($0)","seq":\#($0)}"#
        }))
        defer {
            try? FileManager.default.removeItem(at: big.url)
            try? FileManager.default.removeItem(at: small.url)
        }

        let store = RecordStore()
        store.load(big)
        await waitUntilLoaded(store)
        XCTAssertEqual(store.rows.count, 40_000)

        store.filter.searchText = "a"
        store.load(small)
        await waitUntilLoaded(store)
        // 留出时间让旧筛选任务（如果没被拦下）迟到
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(store.rows.count, 50)
        XCTAssertEqual(store.visibleRows.count, 50)
        XCTAssertEqual(store.visibleRows.first?.type, "small-0")
    }

    // MARK: 回归：JSON 高亮的键颜色被字符串色覆盖

    func testJsonHighlightKeyColor() {
        let json = """
        {
          "keyName" : 1,
          "other" : "stringValue",
          "note" : "Exit code 1 and null"
        }
        """
        let attr = JsonHighlighter.attributed(json)
        let ns = json as NSString
        func color(at location: Int) -> NSColor? {
            attr.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
        }
        func color(of token: String, offsetBy offset: Int = 0) -> NSColor? {
            color(at: ns.range(of: token).location + offset)
        }
        // 键是紫色，字符串值是红色
        XCTAssertEqual(color(of: "keyName"), NSColor.systemPurple)
        XCTAssertEqual(color(of: "other"), NSColor.systemPurple)
        XCTAssertEqual(color(of: "stringValue"), NSColor.systemRed)
        // 数字与关键字只在字符串之外着色
        XCTAssertEqual(color(of: ": 1,", offsetBy: 2), NSColor.systemBlue)
        XCTAssertEqual(color(of: "code 1", offsetBy: 5), NSColor.systemRed)
        XCTAssertEqual(color(of: "and null", offsetBy: 4), NSColor.systemRed)
    }
}
