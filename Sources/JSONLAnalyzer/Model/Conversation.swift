import Foundation

// MARK: - 会话视图数据

enum ChatKind {
    case user
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
                    let role = payload["role"] as? String ?? "user"
                    let text = joinContentTexts(payload["content"])
                    if !text.isEmpty {
                        emit(role == "assistant" ? .assistant : .user, row, title: nil, body: text)
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
                let kind: ChatKind = role == "assistant" ? .assistant : .user
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
