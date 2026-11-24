import SwiftUI

enum FieldSort: String, CaseIterable, Identifiable {
    case count = "按次数"
    case path = "按路径"
    var id: String { rawValue }
}

struct FieldsTab: View {
    @EnvironmentObject private var records: RecordStore
    @State private var search = ""
    @State private var sort: FieldSort = .count

    private var rows: [FieldStats] {
        var list = records.fields
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            list = list.filter {
                $0.path.lowercased().contains(needle)
                    || $0.example.lowercased().contains(needle)
            }
        }
        switch sort {
        case .count: list.sort { $0.count != $1.count ? $0.count > $1.count : $0.path < $1.path }
        case .path: list.sort { $0.path < $1.path }
        }
        return list
    }

    var body: some View {
        Group {
            if records.fields.isEmpty {
                if case .done = records.state {
                    Text("没有可分析的字段").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("解析中…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("筛选路径或示例值", text: $search)
                            .textFieldStyle(.roundedBorder).controlSize(.small)
                        Picker("排序", selection: $sort) {
                            ForEach(FieldSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.menu).controlSize(.small)
                        Spacer()
                        Text("\(rows.count) 条路径 · 频率 = 出现次数 ÷ \(records.overview.validLines) 行有效记录")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)

                    Table(rows) {
                        TableColumn("路径") { f in
                            Text(f.path)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                                .help(f.path)
                        }
                        .width(min: 160, ideal: 280)

                        TableColumn("次数") { f in
                            Text("\(f.count)").font(.caption.monospacedDigit())
                        }
                        .width(50)

                        TableColumn("频率") { f in
                            Text(coverage(f)).font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .help("出现次数 ÷ 有效行数；数组元素路径可能超过 100%")
                        }
                        .width(56)

                        TableColumn("类型") { f in
                            Text(f.typesLabel)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        .width(min: 70, ideal: 110)

                        TableColumn("示例") { f in
                            Text(f.example.isEmpty ? "—" : f.example)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1).truncationMode(.tail)
                                .help(f.example)
                        }
                    }
                    .tableStyle(.inset)
                }
            }
        }
    }

    private func coverage(_ f: FieldStats) -> String {
        guard records.overview.validLines > 0 else { return "—" }
        return String(format: "%.0f%%", Double(f.count) / Double(records.overview.validLines) * 100)
    }
}
