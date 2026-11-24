import SwiftUI

// MARK: - 共享格式化

enum Fmt {
    static let timeOfDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static let fullTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func size(_ n: Int64) -> String { bytes.string(fromByteCount: n) }
    static func lineSize(_ n: Int) -> String {
        bytes.string(fromByteCount: Int64(n))
    }

    static func duration(_ s: Double) -> String { CLIStats.formatDuration(s) }
}

/// 类型徽标的稳定颜色（djb2 哈希 → 色相）。
func typeColor(_ s: String) -> Color {
    var h: UInt64 = 5381
    for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
    return Color(hue: Double(h % 360) / 360, saturation: 0.42, brightness: 0.72)
}

struct TypeBadge: View {
    let text: String
    var invalid: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(invalid ? Color.red.opacity(0.18) : typeColor(text).opacity(0.22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(invalid ? Color.red.opacity(0.5) : typeColor(text).opacity(0.45),
                                  lineWidth: 0.5)
            )
            .foregroundColor(invalid ? .red : typeColor(text))
            .help(text)
    }
}

/// 详情页共用的搜索栏：输入即高亮，支持上一个/下一个匹配（循环滚动）。
struct SearchBar: View {
    @Binding var text: String
    @Binding var matchIndex: Int
    let matchCount: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption).foregroundStyle(.secondary)
            TextField("搜索并高亮", text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 185)
                .onChange(of: text) { _ in matchIndex = 0 }
            if matchCount > 0 {
                Text("\(min(max(matchIndex, 0), matchCount - 1) + 1)/\(matchCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                Button {
                    matchIndex = (matchIndex - 1 + matchCount) % matchCount
                } label: { Image(systemName: "chevron.up") }
                    .controlSize(.small)
                    .help("上一个匹配 (↩)")
                Button {
                    matchIndex = (matchIndex + 1) % matchCount
                } label: { Image(systemName: "chevron.down") }
                    .controlSize(.small)
                    .help("下一个匹配")
            } else if !text.isEmpty {
                Text("无匹配").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}
