import SwiftUI
import Charts

struct OverviewTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var records: RecordStore

    private var ov: OverviewStats { records.overview }

    var body: some View {
        Group {
            switch records.state {
            case .idle:
                Text("等待文件").foregroundStyle(.secondary)
            case .loading:
                ProgressView("解析中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let msg):
                Text(msg).foregroundStyle(.secondary)
            case .done:
                content
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statGrid
                if !ov.typeCounts.isEmpty { typeChart }
                if !ov.tokenTotals.isEmpty { tokenCard }
                if ov.invalidLines > 0 { invalidCard }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 概要网格

    private var statGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 7) {
            GridRow {
                stat("总行数", "\(ov.totalLines)")
                stat("有效 / 损坏", "\(ov.validLines) / \(ov.invalidLines)")
                stat("类型数", "\(ov.distinctTypes)")
            }
            GridRow {
                stat("最大行", Fmt.lineSize(ov.maxLineLength))
                stat("平均行", ov.validLines > 0 ? Fmt.lineSize(records.file.map { Int($0.dataSize) / max(ov.validLines, 1) } ?? 0) : "—")
                stat("文件大小", sizeText)
            }
            if let a = ov.firstTime, let b = ov.lastTime {
                GridRow {
                    stat("起始时间", Fmt.fullTime.string(from: a))
                    stat("结束时间", Fmt.fullTime.string(from: b))
                    stat("时间跨度", Fmt.duration(b.timeIntervalSince(a)))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background))
    }

    private var sizeText: String {
        guard let f = records.file else { return "—" }
        return Fmt.size(f.originalSize) + (f.isCompressed ? "（解压后 \(Fmt.size(f.dataSize))）" : "")
    }

    // MARK: 类型分布图

    private var topTypes: [(String, Int)] {
        ov.typeCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(15).map { ($0.key, $0.value) }
    }

    private var typeChart: some View {
        card("类型分布（前 15）") {
            Chart(topTypes, id: \.0) { item in
                BarMark(
                    x: .value("数量", item.1),
                    y: .value("类型", item.0.count > 30 ? "…" + item.0.suffix(28) : item.0)
                )
                .foregroundStyle(by: .value("类型", item.0))
                .annotation(position: .trailing) {
                    Text("\(item.1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .chartXAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: CGFloat(topTypes.count) * 24 + 10)
        }
    }

    // MARK: Token 卡片

    private var tokenCard: some View {
        card("Token 用量合计") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 22) {
                    ForEach(ov.tokenTotals.sorted { $0.key < $1.key }, id: \.key) { k, v in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k).font(.caption).foregroundStyle(.secondary)
                            Text(Int(v).formatted()).font(.title3.monospacedDigit().weight(.semibold))
                        }
                    }
                }
                // 口径自适应（TokenUsageRules.displaySums）：
                // Codex 的 input 已含缓存 → 净输入 = input − cached；
                // Claude 的 input 不含缓存 → 输入合计 = input + cached
                let input = ov.tokenTotals["输入"] ?? 0
                let cached = ov.tokenTotals["缓存读"] ?? 0
                let output = ov.tokenTotals["输出"] ?? 0
                let sums = TokenUsageRules.displaySums(input: input, cached: cached, output: output)
                HStack(spacing: 16) {
                    Text("\(sums.inputIncludesCached ? "净输入" : "输入合计") \(Int(sums.net).formatted())")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text("混合总量 \(Int(sums.blended).formatted())")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.tint)
                }
                Text(sums.inputIncludesCached
                     ? "输入已含缓存读；推理是输出的子集，不计入混合总量。Codex 只统计 token_usage_record 的单次用量。"
                     : "Claude 的 input 不含缓存读，输入合计 = 输入 + 缓存读。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: 损坏行

    private var invalidRows: [RecordRow] { records.rows.filter(\.isInvalid) }

    private var invalidCard: some View {
        card("损坏行（\(ov.invalidLines)）") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(invalidRows.prefix(20)) { r in
                    Button {
                        model.selectedRow = r
                    } label: {
                        HStack(spacing: 8) {
                            Text("行 \(r.id)").font(.caption.monospacedDigit())
                            Text(r.invalidMessage ?? "").font(.caption).lineLimit(1)
                                .foregroundStyle(.red)
                        }
                    }
                    .buttonStyle(.link)
                }
                if invalidRows.count > 20 {
                    Text("…另有 \(invalidRows.count - 20) 行")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 复用

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background))
    }
}
