import SwiftUI
import Charts

struct TimelineTab: View {
    @EnvironmentObject private var records: RecordStore

    /// 图表最多展示的类型数
    private let maxTypes = 8

    private var topTypes: [String] {
        records.overview.typeCounts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maxTypes).map(\.key)
    }

    private var timedRows: [RecordRow] {
        records.rows.filter { $0.time != nil && $0.type != nil && topTypes.contains($0.type!) }
    }

    private var timedPoints: [TokenPoint] {
        records.tokenPoints.filter { $0.time != nil }
    }

    var body: some View {
        Group {
            if case .done = records.state {
                if records.overview.firstTime == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.slash")
                            .font(.system(size: 26)).foregroundStyle(.tertiary)
                        Text("未检测到时间字段（time / timestamp / ts / createdAt）")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if !timedRows.isEmpty { eventChart }
                            if !records.durations.isEmpty { durationCard }
                            if !records.tokenPoints.isEmpty { tokenCard }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                ProgressView("解析中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: 事件散点图

    private var eventChart: some View {
        card("事件时间线（按类型，前 \(maxTypes) 类）") {
            Chart(timedRows.prefix(20000), id: \.id) { r in
                PointMark(
                    x: .value("时间", r.time!),
                    y: .value("类型", r.typeLabel)
                )
                .foregroundStyle(by: .value("类型", r.typeLabel))
                .symbolSize(16)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute().second(),
                                   centered: false)
                }
            }
            .chartLegend(.visible)
            .frame(height: CGFloat(topTypes.count) * 34 + 30)
        }
    }

    // MARK: 时长卡片

    private var avgDuration: Double {
        guard !records.durations.isEmpty else { return 0 }
        return records.durations.map(\.seconds).reduce(0, +) / Double(records.durations.count)
    }

    private var durationCard: some View {
        card("区间时长（\(records.durations.count) 对 start/end · 平均 \(Fmt.duration(avgDuration))）") {
            Table(records.durations.prefix(100).map { $0 }) {
                TableColumn("区间") { d in Text(d.prefix).font(.system(size: 11, design: .monospaced)) }
                TableColumn("开始") { d in
                    Text(Fmt.timeOfDay.string(from: d.start)).font(.caption.monospacedDigit())
                }
                .width(90)
                TableColumn("时长") { d in
                    Text(Fmt.duration(d.seconds)).font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(70)
            }
            .tableStyle(.bordered)
            .frame(height: min(CGFloat(records.durations.count) * 24 + 40, 260))
        }
    }

    // MARK: Token 曲线

    private var tokenCard: some View {
        card("Token 用量随时间") {
            VStack(alignment: .leading, spacing: 4) {
                Chart {
                    ForEach(timedPoints) { p in
                        LineMark(
                            x: .value("时间", p.time!),
                            y: .value("Tokens", p.input),
                            series: .value("指标", "输入")
                        )
                        .foregroundStyle(by: .value("指标", "输入"))
                        .symbol(.circle)
                        .symbolSize(20)
                    }
                    ForEach(timedPoints) { p in
                        LineMark(
                            x: .value("时间", p.time!),
                            y: .value("Tokens", p.output),
                            series: .value("指标", "输出")
                        )
                        .foregroundStyle(by: .value("指标", "输出"))
                        .symbol(.square)
                        .symbolSize(20)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .chartLegend(.visible)
                .frame(height: 220)

                Text("每个点是一次请求的用量快照（同一条记录里重复的 usage 只计一次）。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 复用

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
