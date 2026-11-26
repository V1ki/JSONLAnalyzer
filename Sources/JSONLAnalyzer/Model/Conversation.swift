import Foundation
import AppKit

// MARK: - 会话视图数据

enum ChatKind {
    case user
    /// 系统提示词、给模型的指令（Codex 的 developer / system 角色、注入的上下文）
    case system
    case assistant
    case reasoning
    case toolCall
    case toolOutput
    case marker
}

struct ChatEntry: Identifiable {
    let id: Int
    let kind: ChatKind
    let lineNo: Int
    let time: Date?
    /// 工具名 / marker 文本 / 角色说明
    let title: String?
    /// 正文：消息文本、调用参数、工具输出
    let body: String
    /// call_id 等补充信息
    let meta: String?
}

/// 把已解析的 JSONL 行还原成对话流。
/// 兼容三种来源：
/// - DSH：user/message、assistant/message（content[]：text/reasoning/tool-call）、tool/call、tool/result
/// - Codex：response_item（message/function_call(+output)/custom_tool_call(+output)/reasoning）、
///   turn_context、compacted、session_meta
/// - Claude：user/assistant（message.content[]：text/tool_use/tool_result/thinking）
enum ConversationBuilder {
    static let bodyLimit = 40_000

    /// idBase：起始条目 id，流式构建时由调用方接着上一批编号
    static func build(_ pairs: [(row: RecordRow, dict: [String: Any])], idBase: Int = 0) -> [ChatEntry] {
        var out: [ChatEntry] = []
        out.reserveCapacity(pairs.count / 2)
        var nextId = idBase
        func emit(_ kind: ChatKind, _ row: RecordRow, title: String?, body: String, meta: String? = nil) {
            // String.count 是 O(n)：先用 O(1) 的 utf8.count 排除没超限的，绝大多数条目到这一步就结束
            let tooLong = body.utf8.count > bodyLimit && body.count > bodyLimit
            let trimmed = tooLong ? String(body.prefix(bodyLimit)) + "\n…（已截断）" : body
            out.append(ChatEntry(id: nextId, kind: kind, lineNo: row.id,
                                 time: row.time, title: title, body: trimmed, meta: meta))
            nextId += 1
        }
        for (row, dict) in pairs where !row.isInvalid {
            let type = row.type ?? ""
            let subtype = row.subtype ?? ""

            // ---- Codex ----
            if type == "session_meta" {
                let payload = dict["payload"] as? [String: Any]
                let cwd = (payload?["cwd"] as? String) ?? ""
                let model = (payload?["model"] as? String) ?? ""
                emit(.marker, row,
                     title: "会话开始",
                     body: [cwd.isEmpty ? nil : "工作区 \(cwd)", model.isEmpty ? nil : "模型 \(model)"]
                         .compactMap { $0 }.joined(separator: " · "))
            } else if type == "turn_context" {
                if let payload = dict["payload"] as? [String: Any],
                   let model = payload["model"] as? String, !model.isEmpty {
                    emit(.marker, row, title: "Turn 开始", body: "模型 \(model)")
                }
            } else if type == "compacted" {
                emit(.marker, row, title: "上下文压缩", body: "此前的原始历史已被压缩摘要替代")
            } else if type == "response_item" {
                let payload = dict["payload"] as? [String: Any] ?? [:]
                switch subtype {
                case "message":
                    let text = joinContentTexts(payload["content"])
                    if !text.isEmpty {
                        emit(kind(forRole: payload["role"] as? String), row, title: nil, body: text)
                    }
                case "function_call", "custom_tool_call", "local_shell_call", "tool_search_call":
                    // 不同变体的参数字段：function_call.arguments / custom_tool_call.input /
                    // local_shell_call.action / tool_search_call.query
                    let arg = payload["arguments"] ?? payload["input"]
                        ?? payload["action"] ?? payload["query"]
                    emit(.toolCall, row,
                         title: (payload["name"] as? String) ?? subtype,
                         body: prettyJSONString(arg),
                         meta: payload["call_id"] as? String)
                case "function_call_output", "custom_tool_call_output", "tool_search_output":
                    emit(.toolOutput, row,
                         title: subtype.replacingOccurrences(of: "_output", with: ""),
                         body: outputText(payload["output"]).ifEmpty("（空输出）"),
                         meta: payload["call_id"] as? String)
                case "reasoning":
                    let summary = joinContentTexts(payload["summary"])
                    let content = joinContentTexts(payload["content"])
                    let text = summary.isEmpty ? content : summary
                    if !text.isEmpty { emit(.reasoning, row, title: nil, body: text) }
                default:
                    break
                }
                continue
            }

            // ---- DSH ----
            if type == "user/message" || type == "assistant/message" {
                // 两种形态：data.message.{role,content}（assistant）或 data.{role,content}（user）
                let data = dict["data"] as? [String: Any]
                let message = (data?["message"] as? [String: Any]) ?? data
                let role = message?["role"] as? String ?? (data?["role"] as? String) ?? ""
                let kind = kind(forRole: role)
                if let content = message?["content"] as? [[String: Any]] {
                    for item in content {
                        emitContentItem(item, kind: kind, row: row, emit: emit)
                    }
                }
            } else if type == "tool/call" {
                let message = (dict["data"] as? [String: Any])?["message"] as? [String: Any]
                let item = (message?["content"] as? [[String: Any]])?.first
                if let item {
                    emit(.toolCall, row,
                         title: (item["name"] as? String) ?? "tool",
                         body: prettyJSONString(item["arguments"]),
                         meta: item["id"] as? String)
                }
            } else if type == "tool/result" {
                let message = (dict["data"] as? [String: Any])?["message"] as? [String: Any]
                if let content = message?["content"] as? [[String: Any]] {
                    for item in content {
                        emitContentItem(item, kind: .user, row: row, emit: emit)
                    }
                }
                continue
            }

            // ---- Claude ----
            if type == "user" || type == "assistant" {
                let kind: ChatKind = type == "assistant" ? .assistant : .user
                guard let message = dict["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                for item in content {
                    switch item["type"] as? String {
                    case "text":
                        if let t = item["text"] as? String, !t.isEmpty {
                            emit(kind, row, title: nil, body: t)
                        }
                    case "thinking":
                        if let t = item["thinking"] as? String, !t.isEmpty {
                            emit(.reasoning, row, title: nil, body: t)
                        }
                    case "tool_use":
                        emit(.toolCall, row,
                             title: (item["name"] as? String) ?? "tool",
                             body: prettyJSONString(item["input"]),
                             meta: item["id"] as? String)
                    case "tool_result":
                        emit(.toolOutput, row, title: "工具输出",
                             body: claudeResultText(item["content"]),
                             meta: item["tool_use_id"] as? String)
                    default:
                        break
                    }
                }
            }
        }
        return out
    }

    /// 流式构建：用同一个文件句柄逐行回读、解析、建条目，解析树用完即弃——
    /// 内存只与条目正文总量相关，不随文件大小增长（批量的 build 会把整份文件的解析树留在内存里）。
    /// 任务被取消时返回 nil。
    static func buildStreaming(_ file: JsonlFile, rows: [RecordRow]) -> [ChatEntry]? {
        guard let reader = file.openRowReader() else { return [] }
        var out: [ChatEntry] = []
        out.reserveCapacity(rows.count / 2)
        var processed = 0
        for r in rows where !r.isInvalid {
            processed += 1
            if processed & 0xFF == 0, Task.isCancelled { return nil }
            // JSONSerialization 的产物都是自动释放的：逐行排空，不让它们攒到任务挂起
            autoreleasepool {
                guard let data = reader.read(offset: r.offset, length: r.length),
                      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
                out.append(contentsOf: build([(r, dict)], idBase: out.count))
            }
        }
        return out
    }

    /// 行号最接近 line 的条目（条目按行号递增）。优先行号相同的首个条目；
    /// 没有对应条目的行（如 token_count 事件）取行号最近的，距离相同取靠前的。
    static func nearestEntry(to line: Int, in entries: [ChatEntry]) -> ChatEntry? {
        guard !entries.isEmpty else { return nil }
        // 二分找第一个 lineNo >= line 的位置
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].lineNo < line { lo = mid + 1 } else { hi = mid }
        }
        if lo == 0 { return entries[0] }
        if lo == entries.count { return entries[entries.count - 1] }
        let before = entries[lo - 1], after = entries[lo]
        return (line - before.lineNo) <= (after.lineNo - line) ? before : after
    }

    // MARK: - 正文的 Markdown 显示

    /// 正文按显示方式切成的片段：表格要画成真正的列（单元格自动换行），
    /// 富文本画不出来，所以单独成一段，其余的交给 Markdown 渲染器。
    enum BodySegment: Equatable {
        case markdown(String)
        case table(rows: [[String]])
    }

    /// 把 Markdown 源文本按表格切段。不是表格的行原样保留（含空行），拼回去与原文相同。
    static func splitTables(_ body: String) -> [BodySegment] {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        var out: [BodySegment] = []
        var text: [Substring] = []
        var i = 0
        while i < lines.count {
            if tableHeaderIndex(i, lines) != nil {
                if !text.isEmpty { out.append(.markdown(text.joined(separator: "\n"))); text = [] }
                var rows = [tableCells(lines[i])]
                i += 2                                  // 表头行、分隔行
                while i < lines.count, isTableRow(lines[i]) {
                    rows.append(tableCells(lines[i]))
                    i += 1
                }
                out.append(.table(rows: rows))
            } else {
                text.append(lines[i])
                i += 1
            }
        }
        if !text.isEmpty { out.append(.markdown(text.joined(separator: "\n"))) }
        return out
    }

    /// lines[i] 是表头（下一行是分隔行）时返回 i
    private static func tableHeaderIndex(_ i: Int, _ lines: [Substring]) -> Int? {
        guard i + 1 < lines.count, isTableRow(lines[i]), isTableSeparator(lines[i + 1]) else { return nil }
        return i
    }

    /// 表格行：以竖线开头，且至少还有一个竖线。
    /// 只认以竖线开头的行：`说明 | 附注` 这种行在正文里很常见，认它会在段落中间冒出假表格；
    /// 真正的表格几乎总写成首尾都带竖线的形式。
    private static func isTableRow(_ line: Substring) -> Bool {
        let t = line.trimmed
        return t.hasPrefix("|") && t.dropFirst().contains("|")
    }

    /// 分隔行 `|---|:---:|`：每格只由 - : 空格组成，至少一格有 -
    private static func isTableSeparator(_ line: Substring) -> Bool {
        guard isTableRow(line), line.contains("-") else { return false }
        return tableCells(line).allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            return c.contains("-") && c.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
        }
    }

    /// 按未转义的竖线拆单元格；首尾的竖线去掉
    private static func tableCells(_ line: Substring) -> [String] {
        var t = line.trimmed
        if t.hasPrefix("|") { t = t.dropFirst() }
        if t.hasSuffix("|") { t = t.dropLast() }
        var cells: [String] = [], cur = "", escaped = false
        for ch in t {
            if escaped {
                cur.append("\\")
                cur.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            } else {
                cur.append(ch)
            }
        }
        if escaped { cur.append("\\") }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// 这一条正文是否按 Markdown 渲染显示。
    ///
    /// - 助手回复、推理摘要、系统消息都是大段 Markdown（标题、列表、代码块），一律渲染：
    ///   按原文铺出来会把 `**加粗**`、`## 标题` 这些标记直接露在外面。
    /// - 工具输出不渲染：多半是命令行日志、JSON，`*` 和 `_` 出现在路径或分隔线里是常事，
    ///   `# pass 59` 这样的汇总行也不是标题。
    /// - 用户输入、工具调用的参数则文档和代码/普通文字都有，按 looksLikeDocument 判断：
    ///   只有开头不是代码、正文里有标题、加粗小节或表格的才当文档。
    ///   用户消息开头的包裹标签（`<skill>` 里的 SKILL.md）不算正文，先去掉再判断。
    ///
    /// 这只是默认值：气泡的右键菜单里可以逐条手动切换。
    static func rendersMarkdown(kind: ChatKind, body: String) -> Bool {
        switch kind {
        case .assistant, .reasoning, .system:
            return true
        case .user:
            return looksLikeDocument(droppingLeadingTags(body))
        case .toolCall:
            return looksLikeDocument(body)
        case .toolOutput, .marker:
            return false
        }
    }

    /// 正文是不是一篇写给人读的 Markdown 文档（而不是代码、补丁、JSON、普通对话）。
    ///
    /// 真实数据里，带 Markdown 标记的工具调用参数几乎全是代码：`cat > README.md <<'EOF'`
    /// 写进去的正文、补丁里改动的标题行，标记只是它们要写入的内容。所以光看有没有标记不行，
    /// 要两头都看：开头不是代码，正文里再有标题、加粗小节或表格中的一处。
    /// 列表、行内加粗这些不算：普通输入里也常有两三条列表，照样原样显示。
    static func looksLikeDocument(_ body: String) -> Bool {
        looksLikeDocument(body[...])
    }

    static func looksLikeDocument(_ body: Substring) -> Bool {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        var i = 0
        while i < lines.count, lines[i].trimmed.isEmpty { i += 1 }
        guard i < lines.count else { return false }
        let first = lines[i].trimmed
        if looksLikeCode(first) { return false }
        // 标题在首行（或首行就是表头）
        var found = headingLevel(first) != nil
            || (i + 1 < lines.count && isTableRow(first) && isTableSeparator(lines[i + 1]))
        // 单个 # 开头的可能是文档标题，也可能是脚本的第一行注释：注释后面紧跟代码
        var afterComment = headingLevel(first) == 1
        i += 1
        while i < lines.count {
            let t = lines[i].trimmed
            i += 1
            if t.isEmpty { continue }
            if let level = headingLevel(t) {
                found = found || level >= 2   // 单个 # 的与注释分不清，不当结构
            } else if isBoldHeading(t) {
                found = true
            } else if isTableRow(t) {
                if i < lines.count, isTableSeparator(lines[i]) { found = true }
            } else if afterComment {
                // 文档里常有 <INSTRUCTIONS>、<system-reminder> 这样的包裹标签，不是代码
                if t.first != "<", looksLikeCode(t) { return false }
                afterComment = false
            }
            // 标题后的那一行已经看过不是代码，就不必再往下找了
            if found && !afterComment { break }
        }
        return found && !isTranscript(lines)
    }

    /// 对话记录转储（审批评估用的历史、子代理的往来）：`[166] assistant: …`、`user: …` 这样的记录行。
    /// 里面的标题、表格是别人说过的话，不是这篇正文自己的结构。记录行出现两行以上就不当文档。
    private static func isTranscript(_ lines: [Substring]) -> Bool {
        var count = 0
        for line in lines.prefix(400) {
            if isTranscriptLine(line.trimmed) {
                count += 1
                if count >= 2 { return true }
            }
        }
        return false
    }

    /// `[21] tool js call: {…}`、`user: 其次,…`、`assistant: **有。…`
    private static func isTranscriptLine(_ t: Substring) -> Bool {
        var s = t
        if s.first == "[" {
            let digits = s.dropFirst().prefix(while: \.isNumber)
            let afterDigits = s.dropFirst(1 + digits.count)
            guard !digits.isEmpty, digits.count <= 7, afterDigits.first == "]" else { return false }
            s = afterDigits.dropFirst().trimmed
        }
        let role = s.prefix(while: \.isLetter)
        switch role.lowercased() {
        case "user", "assistant", "system", "developer":
            return s.dropFirst(role.count).first == ":"
        case "tool":
            // `tool js call: …`、`tool exec result: …`：角色后面是工具名和动作，再是冒号
            let after = s.dropFirst(role.count)
            return after.first == " " && after.prefix(40).contains(":")
        default:
            return false
        }
    }

    /// 消息角色对应的条目类型。developer / system 是给模型看的指令（系统提示词、注入的上下文），
    /// 不是用户说的话
    private static func kind(forRole role: String?) -> ChatKind {
        switch role {
        case "assistant": return .assistant
        case "developer", "system": return .system
        default: return .user
        }
    }

    /// 去掉正文开头连续的包裹标签行，返回剩下的正文。
    ///
    /// 自动注入的用户消息常把文档包在标签里：`<skill>` 里是一整篇 SKILL.md。标签不是文档本身，
    /// 留着的话开头就成了「结构化数据」，里面的文档永远渲染不了。去掉两类：
    /// 独占一行的块标签（`<skill>`、`<in-app-browser-context source="…">`），
    /// 和同一行闭合的元数据（`<name>xxx</name>`、`<path>…</path>`）。
    /// `<multi_agent_role>You are…` 这种标签后紧跟正文的，标签是正文的一部分，不去。
    static func droppingLeadingTags(_ body: String) -> Substring {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        var i = 0, removed = 0
        while removed < 6, i < lines.count {
            let t = lines[i].trimmed
            if t.isEmpty { i += 1; continue }
            guard let tag = leadingTag(t) else { break }
            let name = tag.dropFirst().dropLast().prefix { $0 != " " && $0 != "\t" }
            let rest = t.dropFirst(tag.count).trimmed
            guard rest.isEmpty || rest.hasSuffix("</\(name)>") else { break }
            i += 1
            removed += 1
        }
        // 从第一条保留的行开始，到正文末尾
        return i < lines.count ? body[lines[i].startIndex...] : body.suffix(0)
    }

    /// 行首完整的一个开标签：`<skill>`、`<in-app-browser-context source="…">`。不是的话返回 nil
    private static func leadingTag(_ t: Substring) -> Substring? {
        guard t.first == "<", t.count > 2 else { return nil }
        let inner = t.dropFirst()
        guard let first = inner.first, first.isASCII, first.isLetter || first == "_" else { return nil }
        guard let close = inner.firstIndex(of: ">") else { return nil }
        return t[..<inner.index(after: close)]
    }

    /// 一行看起来是代码、补丁或结构化数据，而不是写给人读的文字
    private static func looksLikeCode(_ t: Substring) -> Bool {
        // 补丁、diff
        if t.hasPrefix("*** ") || t.hasPrefix("@@ ") || t.hasPrefix("diff ") || t.hasPrefix("Index: ") { return true }
        // 注释、shebang、XML 声明
        if t.hasPrefix("//") || t.hasPrefix("/*") || t.hasPrefix("*/") || t.hasPrefix("#!")
            || t.hasPrefix("<?") || t.hasPrefix("<!--") { return true }
        // 以开花括号、续行符、分号结尾的行
        if t.hasSuffix("{") || t.hasSuffix("\\") || t.hasSuffix("=>") || t.hasSuffix(";") { return true }
        if let first = t.first {
            // JSON 对象、数组（`[文字](链接)` 的方括号后面跟着的不是引号或花括号，不受影响）
            if first == "{" { return true }
            if first == "[", t.count == 1 || t.dropFirst().first == "\"" || t.dropFirst().first == "{" { return true }
            if first == "<", let next = t.dropFirst().first, next.isLetter || next == "/" { return true }
            // 装饰器、注解
            if first == "@", t.dropFirst().first?.isLetter == true { return true }
            // diff 的新增行（`+ ` 开头是 Markdown 的列表符号，不算）
            if first == "+", let next = t.dropFirst().first, next != " " { return true }
        }
        // 语句：关键字开头、函数调用 name(…) / a.b(…)、赋值 x = …
        var rest = t
        var head: Substring?
        while let f = rest.first, f.isASCII, f.isLetter || f == "_" {
            let word = rest.prefix { $0.isASCII && $0.isLetter || $0.isNumber || $0 == "_" }
            if head == nil { head = word }
            rest = rest.dropFirst(word.count)
            // 点号后面还是标识符：链式调用
            if rest.first == ".", let next = rest.dropFirst().first, next.isASCII, next.isLetter || next == "_" {
                rest = rest.dropFirst()
                continue
            }
            break
        }
        guard let head else { return false }
        // 紧跟括号是函数调用 name(…)；赋值 `x = …` 的等号前可以有空格
        if rest.first == "(" { return true }
        let afterSpaces = rest.drop { $0 == " " || $0 == "\t" }
        if afterSpaces.first == "=" { return true }
        if afterSpaces.first == ":", afterSpaces.dropFirst().first == "=" { return true }
        if let op = afterSpaces.first, "+-*/%&|^!?<>".contains(op), afterSpaces.dropFirst().first == "=" { return true }
        return codeKeywords.contains(String(head))
    }

    /// 一看就是代码的行首词。只收不会作为普通文字出现在行首的（小写、区分大小写）；
    /// `use`、`make`、`new` 这类英文里常见的词不收，它们写的语句多半带着括号或等号，另有判断。
    private static let codeKeywords: Set<String> = [
        // 语句
        "import", "export", "from", "package", "return", "function", "fn", "func", "def", "class", "struct",
        "enum", "interface", "async", "await", "yield", "const", "let", "var", "static", "throw", "raise",
        "elif", "except", "if", "for", "while", "switch", "try", "catch",
        // 命令
        "cd", "ls", "cat", "mkdir", "rm", "mv", "cp", "sudo", "git", "grep", "sed", "awk", "curl", "wget",
        "chmod", "tar", "pip", "npm", "npx", "yarn", "bun", "node", "python", "python3", "docker", "kubectl",
        "cargo", "swift", "xcodebuild", "eval", "exec", "set", "unset",
    ]

    /// `# 标题` 到 `###### 标题`（# 后面是空格或制表符）：1…6；不是标题返回 nil
    private static func headingLevel(_ t: Substring) -> Int? {
        var n = 0
        for ch in t {
            if ch == "#" { n += 1 } else { break }
        }
        guard (1...6).contains(n) else { return nil }
        let after = t.dropFirst(n)
        return after.first == " " || after.first == "\t" ? n : nil
    }

    /// 整行只有一段加粗：`**一、结果**`（末尾可以带冒号、句号），文档里常拿来当小节标题
    private static func isBoldHeading(_ t: Substring) -> Bool {
        var s = t
        while let last = s.last, ":：.。,，;；!！?？ ".contains(last) { s = s.dropLast() }
        guard s.hasPrefix("**"), s.hasSuffix("**"), s.count > 4 else { return false }
        return !s.dropFirst(2).dropLast(2).contains("**")
    }

    /// 折叠时只显示富文本的前几行：在换行符处截断，不会把标题或加粗这样的属性从中间切开
    static func clipping(_ attr: NSAttributedString, toLines maxLines: Int) -> NSAttributedString {
        let ns = attr.string as NSString
        var lines = 1, i = 0
        while i < ns.length && lines < maxLines {
            if ns.character(at: i) == 0x0A { lines += 1 }
            i += 1
        }
        guard i < ns.length else { return attr }
        let out = NSMutableAttributedString(attributedString: attr.attributedSubstring(from: NSRange(location: 0, length: i)))
        out.append(NSAttributedString(string: "…\n", attributes: [
            .font: NSFont.systemFont(ofSize: MarkdownRenderer.bodySize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return out
    }

    // MARK: - 字段提取辅助

    /// DSH content 数组项：text / reasoning / tool-call / tool-result（嵌套 content）
    private static func emitContentItem(
        _ item: [String: Any], kind: ChatKind, row: RecordRow,
        emit: (ChatKind, RecordRow, String?, String, String?) -> Void
    ) {
        switch item["type"] as? String {
        case "text":
            if let t = item["text"] as? String, !t.isEmpty {
                emit(kind, row, nil, t, nil)
            }
        case "reasoning":
            if let t = item["text"] as? String, !t.isEmpty {
                emit(.reasoning, row, nil, t, nil)
            }
        case "tool-call":
            emit(.toolCall, row,
                 (item["name"] as? String) ?? "tool",
                 prettyJSONString(item["arguments"]),
                 item["id"] as? String)
        case "tool-result":
            // {type:"tool-result", toolCallId, content:[{type:"text",text}]}
            let body = joinContentTexts(item["content"])
            emit(.toolOutput, row, "工具输出",
                 body.isEmpty ? "（空输出）" : body,
                 item["toolCallId"] as? String)
        default:
            break
        }
    }

    /// Codex content 数组（input_text/output_text/text/summary_text 等变体）拼接
    static func joinContentTexts(_ content: Any?) -> String {
        guard let arr = content as? [Any] else { return "" }
        var parts: [String] = []
        for el in arr {
            if let d = el as? [String: Any], let t = d["text"] as? String, !t.isEmpty {
                parts.append(t)
            } else if let s = el as? String, !s.isEmpty {
                parts.append(s)
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Codex function_call_output 的 output：字符串或 {content_items:[...]}
    static func outputText(_ output: Any?) -> String {
        if let s = output as? String { return s }
        if let d = output as? [String: Any] {
            if let items = d["content_items"] {
                let t = joinContentTexts(items)
                if !t.isEmpty { return t }
            }
            if let s = d["output"] as? String { return s }
        }
        return ""
    }

    /// Claude tool_result 的 content：字符串或 [{type:text,text}]
    static func claudeResultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        return joinContentTexts(content)
    }

    /// 参数/输入尽量 pretty-print 成 JSON
    static func prettyJSONString(_ value: Any?) -> String {
        guard let value else { return "" }
        if let s = value as? String {
            guard let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                           options: [.prettyPrinted, .sortedKeys]),
                  let out = String(data: pretty, encoding: .utf8) else { return s }
            return out
        }
        if JSONSerialization.isValidJSONObject(value),
           let pretty = try? JSONSerialization.data(withJSONObject: value,
                                                    options: [.prettyPrinted, .sortedKeys]),
           let out = String(data: pretty, encoding: .utf8) {
            return out
        }
        return "\(value)"
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

private extension Substring {
    /// 去掉首尾的空格、制表符、回车（不拷贝字符串）
    var trimmed: Substring {
        var s = self
        while let f = s.first, f == " " || f == "\t" || f == "\r" { s = s.dropFirst() }
        while let l = s.last, l == " " || l == "\t" || l == "\r" { s = s.dropLast() }
        return s
    }
}
