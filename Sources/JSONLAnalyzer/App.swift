import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - AppModel（全局状态）

/// ⌘G 跳转请求（token 用于触发相同行号的重复跳转）
struct JumpRequest: Equatable {
    let line: Int
    let token: Int
}

@MainActor
final class AppModel: ObservableObject {
    let sessions = SessionStore()
    let records = RecordStore()

    @Published var selectedFileID: String?
    @Published var selectedRow: RecordRow?
    @Published var openError: String?
    // ⌘G 跳转到行
    @Published var jumpVisible = false
    @Published var jumpText = ""
    @Published var jumpRequest: JumpRequest?
    /// 右下角"定位"按钮：侧栏文件列表滚动回当前文件的请求令牌
    @Published var locateToken = 0
    /// 关联/跳转导航历史（返回用）
    @Published var navBackStack: [RecordRow] = []

    var jumpTokenBase: Int { jumpRequest?.token ?? 0 }

    /// 关联导航：选中目标行并压入返回栈。
    func navigate(to row: RecordRow) {
        if let cur = selectedRow, cur.id != row.id {
            navBackStack.append(cur)
            if navBackStack.count > 200 { navBackStack.removeFirst() }
        }
        jumpText = "\(row.id)"
        _ = performJump()
    }

    /// 返回上一次导航前的记录。
    func navigateBack() {
        guard let last = navBackStack.popLast() else { return }
        jumpText = "\(last.id)"
        _ = performJump()
    }

    /// 定位当前选中：记录列表滚回选中行（含清筛选），文件列表滚回当前文件。
    func locateSelection() {
        guard selectedFileID != nil else { return }
        locateToken += 1
        if let row = selectedRow {
            jumpText = "\(row.id)"
            performJump()
        }
    }

    func requestJump() {
        guard selectedFileID != nil else { return }
        jumpText = selectedRow.map { "\($0.id)" } ?? ""
        jumpVisible = true
    }

    @discardableResult
    func performJump() -> Bool {
        let n = Int(jumpText.trimmingCharacters(in: .whitespaces)) ?? -1
        guard n >= 1 else {
            openError = "请输入有效的行号"
            return false
        }
        guard !records.rows.isEmpty else {
            openError = "还没有解析完成的记录，请稍候再试"
            return false
        }
        guard let row = records.rows.first(where: { $0.id == n }) else {
            openError = "行号超出范围（1 – \(records.rows.count)）"
            return false
        }
        // 筛选可能把目标行滤掉：先同步清空筛选再跳
        records.resetFilterForJump()
        selectedRow = row
        jumpRequest = JumpRequest(line: n, token: jumpTokenBase + 1)
        return true
    }

    func start() {
        sessions.rescan()
    }

    /// 每次打开递增。准备文件可能很慢（比如解压一个大的 zstd），期间用户又打开了别的文件：
    /// 慢的那一份完成后据此作废，不再加载，也不拿它的错误去覆盖当前文件的状态。
    private var openToken = 0

    /// 打开一个文件（侧栏选择、拖拽、打开面板共用）。
    func open(_ url: URL) {
        openToken += 1
        let token = openToken
        selectedFileID = url.path
        selectedRow = nil
        sessions.insertExternal(url)
        records.beginPreparing()
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let f = try JsonlFile.prepare(url)
                guard await self?.isOpenCurrent(token) == true else { return }
                await self?.records.load(f)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                guard await self?.isOpenCurrent(token) == true else { return }
                await self?.records.loadFailed(msg)
                await self?.setOpenError(msg)
            }
        }
    }

    private func isOpenCurrent(_ token: Int) -> Bool { openToken == token }

    /// 重新解析当前文件（zstd 缓存按 mtime 自动失效）。
    func reload() {
        guard let id = selectedFileID else { return }
        open(URL(fileURLWithPath: id))
    }

    func revealInFinder() {
        guard let id = selectedFileID else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id)])
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "选择 JSONL 文件（支持 .jsonl / .json / .zstd）"
        var types: [UTType] = [.json]
        for ext in ["jsonl", "zstd", "zst"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    private func setOpenError(_ msg: String) { openError = msg }
}

// MARK: - App

@main
struct JSONLAnalyzerApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--stats"), i + 1 < args.count {
            CLIStats.run(path: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--fields"), i + 1 < args.count {
            CLIStats.run(path: args[i + 1], showFields: true)
            exit(0)
        }
        if let i = args.firstIndex(of: "--line"), i + 2 < args.count,
           let n = Int(args[i + 2]) {
            CLIDebug.printLine(path: args[i + 1], line: n)
            exit(0)
        }
        if let i = args.firstIndex(of: "--refs"), i + 2 < args.count,
           let n = Int(args[i + 2]) {
            CLIDebug.printRefs(path: args[i + 1], line: n)
            exit(0)
        }
        if args.contains("--scan") {
            CLIDebug.printScan()
            exit(0)
        }
        if let i = args.firstIndex(of: "--chat"), i + 1 < args.count {
            CLIDebug.printChat(path: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--offsets"), i + 2 < args.count,
           let n = Int(args[i + 2]) {
            CLIDebug.printOffsets(path: args[i + 1], maxLines: n)
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("JSONL Analyzer") {
            MainWindow()
                .environmentObject(model)
                .frame(minWidth: 1080, minHeight: 640)
                .onAppear { model.start() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("打开…") { model.showOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("重新解析") { model.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("在 Finder 中显示") { model.revealInFinder() }
            }
            CommandGroup(after: .toolbar) {
                Button("跳转到行…") { model.requestJump() }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(model.selectedFileID == nil)
                Button("刷新会话列表") { model.sessions.rescan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 从终端直接运行二进制时也能获得正常的激活窗口和菜单栏
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - CLI（--stats / --fields）

enum CLIStats {
    static func run(path: String, showFields: Bool = false) {
        let url = URL(fileURLWithPath: path)
        do {
            let file = try JsonlFile.prepare(url)
            guard let reader = file.openReader() else {
                FileHandle.standardError.write("无法打开文件：\(path)\n".data(using: .utf8)!)
                exit(1)
            }
            var ov = OverviewStats()
            let scanner = LineScanner()
            var number = 0
            while let (line, _) = reader.nextLine() {
                // 同步循环中途不挂起，自动释放的对象要按行排空，否则会攒到进程退出
                autoreleasepool {
                    number += 1
                    ov.totalLines = number
                    // 与 GUI 同一套解析与扫描，统计口径一致
                    let decoded = LineParser.parseAndDecode(line: line, number: number, offset: 0)
                    guard let obj = decoded.object else {
                        ov.invalidLines += 1
                        return
                    }
                    ov.validLines += 1
                    if let dict = decoded.root {
                        let t = LineParser.typeValue(from: dict)
                        let sub = (dict["payload"] as? [String: Any])?["type"] as? String
                        if let t {
                            ov.typeCounts[t, default: 0] += 1
                        }
                        if let time = LineParser.timeValue(from: dict) {
                            if ov.firstTime == nil || time < ov.firstTime! { ov.firstTime = time }
                            if ov.lastTime == nil || time > ov.lastTime! { ov.lastTime = time }
                        }
                        var found = scanner.scan(dict, fields: true,
                                                 tokens: !TokenUsageRules.skipGenericScan(type: t, subtype: sub)).tokens
                        if t == "token_usage_record" {
                            found = TokenUsageRules.normalize(TokenUsageRules.exactUsage(dict: dict))
                        }
                        for (k, v) in found { ov.tokenTotals[k, default: 0] += v }
                    } else {
                        scanner.scan(root: obj, fields: true)     // 根是数组/标量：只做字段聚合
                    }
                }
            }
            print(summary(file: file, overview: ov))
            if showFields {
                print("\n字段路径（前 60，按出现次数；百分比 = 出现次数 ÷ 有效行数，数组元素路径可能超过 100%）：")
                for f in scanner.sortedByCount.prefix(60) {
                    let pct = ov.validLines > 0
                        ? String(format: "%.0f%%", Double(f.count) / Double(ov.validLines) * 100) : "-"
                    print("  \(String(repeating: " ", count: 6 - String(f.count).count))\(f.count) \(pct)\t\(f.path)  [\(f.typesLabel)]")
                }
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
            exit(1)
        }
    }

    private static func summary(file: JsonlFile, overview ov: OverviewStats) -> String {
        let bf = ByteCountFormatter()
        bf.countStyle = .file
        var out = """
        文件: \(file.url.path)
        大小: \(bf.string(fromByteCount: file.originalSize))\
        \(file.isCompressed ? "（解压后 \(bf.string(fromByteCount: file.dataSize))）" : "")
        行数: \(ov.totalLines)（有效 \(ov.validLines)，损坏 \(ov.invalidLines)）
        类型: \(ov.distinctTypes) 种
        """
        if !ov.typeCounts.isEmpty {
            let top = ov.typeCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            out += "\n类型分布（前 15）:"
            let pad = String(top.prefix(15).map(\.value).max() ?? 0).count
            for (k, v) in top.prefix(15) {
                out += "\n  \(String(repeating: " ", count: max(0, pad - String(v).count)))\(v)  \(k)"
            }
        }
        if let a = ov.firstTime, let b = ov.lastTime {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let dur = b.timeIntervalSince(a)
            out += "\n时间: \(df.string(from: a)) ~ \(df.string(from: b))（跨度 \(formatDuration(dur))）"
        }
        if !ov.tokenTotals.isEmpty {
            let parts = ov.tokenTotals.sorted { $0.key < $1.key }
                .map { "\($0.key) \(Int($0.value).formatted())" }
                .joined(separator: " · ")
            out += "\nToken: \(parts)"
            let sums = TokenUsageRules.displaySums(
                input: ov.tokenTotals["输入"] ?? 0,
                cached: ov.tokenTotals["缓存读"] ?? 0,
                output: ov.tokenTotals["输出"] ?? 0)
            out += "\n\(sums.inputIncludesCached ? "净输入" : "输入合计(Claude)") \(Int(sums.net).formatted()) · 混合总量 \(Int(sums.blended).formatted())"
        }
        return out
    }

    static func formatDuration(_ s: Double) -> String {
        if s < 1 { return String(format: "%.0fms", s * 1000) }
        if s < 60 { return String(format: "%.1fs", s) }
        let m = Int(s) / 60, sec = Int(s) % 60
        if m < 60 { return "\(m)m\(sec)s" }
        return "\(m / 60)h\(m % 60)m"
    }
}

// MARK: - CLI 调试（--line <file> <lineNo>：打印某行抽取到的文本字段；--scan：打印 workspace 分组）

enum CLIDebug {
    /// 离屏跑一遍扫描与分组，验证 workspace 提取效果与耗时。
    static func printScan() {
        let t0 = Date()
        var found: [SessionFile] = []
        for src in [SessionSource.dsh, .codex, .claude] {
            guard let root = src.rootPath else { continue }
            found.append(contentsOf: SessionStore.scanDirectory(
                URL(fileURLWithPath: root), source: src))
        }
        found.sort { $0.mtime > $1.mtime }
        let groups = SessionStore.buildGroups(found)
        let elapsed = Date().timeIntervalSince(t0)
        print("扫描 \(found.count) 个文件，\(groups.count) 个分组，耗时 \(String(format: "%.1f", elapsed))s\n")
        for g in groups.prefix(25) {
            let counts = [SessionSource.dsh, .codex, .claude]
                .map { src -> String in "\(src.rawValue) \(g.files.filter { $0.source == src }.count)" }
                .filter { !$0.hasSuffix(" 0") }
            print("  [\(g.latest.formatted(.dateTime.year().month().day()))] \(g.name)  — \(counts.joined(separator: " · "))")
        }
        if groups.count > 25 { print("  … 共 \(groups.count) 组") }
    }

    /// 核对偏移：用生产路径（LineReader 逐行 + readLine 按偏移回读）逐行比对，
    /// 找出解析与回读不一致的行。
    static func printOffsets(path: String, maxLines: Int) {
        do {
            let file = try JsonlFile.prepare(URL(fileURLWithPath: path))
            guard let reader = file.openReader() else {
                print("无法打开文件")
                exit(1)
            }
            var n = 0
            var mismatches = 0
            while let (line, offset) = reader.nextLine() {
                n += 1
                if n > maxLines { break }
                let row = LineParser.parse(line: line, number: n, offset: offset)
                let reread = file.readLine(offset: offset, length: line.count) ?? Data()
                let ok = reread == Data(line)
                let head = String(decoding: line.prefix(60), as: UTF8.self)
                if !ok { mismatches += 1 }
                print("\(ok ? "OK " : "✗✗ ") 行\(n) off=\(offset) len=\(line.count) type=\(row.typeLabel) | \(head)")
            }
            print("\n共 \(min(n, maxLines)) 行，回读不一致 \(mismatches) 行")
        } catch {
            print("错误：\((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            exit(1)
        }
    }

    /// --refs <file> <line>：打印该行的 sequence 引用关系（入向/出向），验证关联索引。
    static func printRefs(path: String, line: Int) {
        do {
            let file = try JsonlFile.prepare(URL(fileURLWithPath: path))
            guard let reader = file.openReader() else {
                print("无法打开文件"); exit(1)
            }
            var seqIdx: [Int64: Int] = [:]
            var refIdx: [Int64: [Int]] = [:]
            var refsByLine: [Int: [SeqRef]] = [:]
            var targetSeq: Int64?
            var targetRef: [SeqRef] = []
            var number = 0
            let scanner = LineScanner()
            while let (bytes, _) = reader.nextLine() {
                number += 1
                let decoded = LineParser.parseAndDecode(line: bytes, number: number, offset: 0)
                let row = decoded.row
                if number == line { targetSeq = row.seq }
                guard let dict = decoded.root else { continue }
                let refs = scanner.scan(dict, seqs: true).refs
                if !refs.isEmpty {
                    if number == line { targetRef = refs }
                    refsByLine[number] = refs
                    for r in refs {
                        for s in r.seqs where s != row.seq {
                            refIdx[s, default: []].append(number)
                        }
                    }
                }
                if let sq = row.seq, seqIdx[sq] == nil { seqIdx[sq] = number }
            }
            guard number >= line else {
                print("文件只有 \(number) 行"); exit(1)
            }

            if targetRef.isEmpty {
                print("出向：第 \(line) 行没有引用其他 sequence")
            } else {
                print("出向（第 \(line) 行引用的）：")
                for r in targetRef {
                    for s in r.seqs {
                        let dst = seqIdx[s].map { "→ 行 \($0)" } ?? "（未找到）"
                        print("  \(r.path): seq \(s) \(dst)")
                    }
                }
            }

            if let seq = targetSeq {
                let incoming = (refIdx[seq] ?? []).filter { $0 != line }.sorted()
                if incoming.isEmpty {
                    print("入向：没有其他行引用 seq \(seq)")
                } else {
                    print("入向（引用了 seq \(seq) 的行）：")
                    for l in incoming {
                        let paths = (refsByLine[l] ?? [])
                            .filter { $0.seqs.contains(seq) }.map(\.path)
                            .joined(separator: ",")
                        print("  行 \(l)  [\(paths)]")
                    }
                }
            } else {
                print("入向：第 \(line) 行没有 seq 字段")
            }
        } catch {
            print("错误：\((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            exit(1)
        }
    }

    /// --chat <file>：验证会话还原（条目统计 + 前若干条）。
    static func printChat(path: String) {
        do {
            let file = try JsonlFile.prepare(URL(fileURLWithPath: path))
            guard let reader = file.openReader() else {
                print("无法打开文件"); exit(1)
            }
            var pairs: [(row: RecordRow, dict: [String: Any])] = []
            var number = 0
            while let (line, _) = reader.nextLine() {
                number += 1
                let decoded = LineParser.parseAndDecode(line: line, number: number, offset: 0)
                if let dict = decoded.root { pairs.append((decoded.row, dict)) }
            }
            let entries = ConversationBuilder.build(pairs)
            var counts: [String: Int] = [:]
            for e in entries {
                counts["\(e.kind)"] = (counts["\(e.kind)"] ?? 0) + 1
            }
            print("共 \(entries.count) 条：\(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))\n")
            for e in entries.prefix(14) {
                let head = e.body.replacingOccurrences(of: "\n", with: "⏎").prefix(60)
                print("[\(e.lineNo)] \(e.kind) \(e.title.map { "\($0) " } ?? "")| \(head)")
            }
        } catch {
            print("错误：\((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            exit(1)
        }
    }

    static func printLine(path: String, line: Int) {
        do {
            let file = try JsonlFile.prepare(URL(fileURLWithPath: path))
            guard let reader = file.openReader() else {
                FileHandle.standardError.write("无法打开文件\n".data(using: .utf8)!)
                exit(1)
            }
            var n = 0
            while let (bytes, _) = reader.nextLine() {
                n += 1
                guard n == line else { continue }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) else {
                    print("第 \(line) 行不是有效 JSON")
                    return
                }
                let cands = TextExtractor.extract(root: obj)
                if cands.isEmpty { print("第 \(line) 行未抽取到文本字段"); return }
                for (i, c) in cands.enumerated() {
                    print("[\(i)] \(c.path) (\(c.length) 字符)")
                    print("    " + c.text.replacingOccurrences(of: "\n", with: "\n    ").prefix(300))
                }
                return
            }
            print("文件只有 \(n) 行")
        } catch {
            FileHandle.standardError.write("\((error as? LocalizedError)?.errorDescription ?? "\(error)")\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
