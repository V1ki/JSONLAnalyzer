import AppKit
import CoreText

// 生成 "JSONL Analyzer" 的 App 图标。
//
// 图标全部用代码画：每个尺寸单独绘制，不靠缩放大图——小尺寸下线条不会糊，
// 细节也能按尺寸单独取舍。想换构图或配色，改下面的枚举就行。
//
// 用法：
//   swift Scripts/MakeIcon.swift build [构图] [配色] [输出目录]
//       生成 AppIcon.png（1024）、AppIcon.icns、AppIcon-preview.png（各尺寸预览）。
//       不带参数就是定稿：bracesBubble / teal / Resources
//   swift Scripts/MakeIcon.swift compare <输出.png>
//       几种构图和配色并排的对比图，换方案之前先看

let args = CommandLine.arguments

// MARK: - 方案

/// 定稿：一对花括号里装着一个对话气泡——JSON 里装着一段对话。
/// 这个工具看的是 AI 对话的 JSONL 日志：花括号是 JSON，气泡是还原出来的会话。
let defaultDesign = Design.bracesBubble
let defaultPalette = Palette.teal

enum Design: String, CaseIterable {
    case bracesBubble    // { 对话气泡 }
    case bracesDots      // { 三行「键 · 值」 }
    case bracesLines     // { 三条彩线 }
}

enum Palette: String, CaseIterable {
    case teal, deepBlue, graphite
    var top: CGColor {
        switch self {
        case .teal:     return rgb(0x1E_5D_59)
        case .deepBlue: return rgb(0x2C_46_6E)
        case .graphite: return rgb(0x45_4B_56)
        }
    }
    var bottom: CGColor {
        switch self {
        case .teal:     return rgb(0x0A_28_29)
        case .deepBlue: return rgb(0x11_20_38)
        case .graphite: return rgb(0x19_1B_20)
        }
    }
    var glow: CGColor {
        switch self {
        case .teal:     return rgb(0x5E_E0_CF, 0.26)
        case .deepBlue: return rgb(0x6F_B2_FF, 0.26)
        case .graphite: return rgb(0xC2_CC_DD, 0.20)
        }
    }
}

/// 对话气泡：和 App 会话视图里「助手」的角色色同一个绿
let bubbleGreen = rgb(0x3D_D6_84)
let dotColors = (rgb(0x3D_D6_84), rgb(0xFF_B3_3D), rgb(0x6F_C5_FF))

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func srgb() -> CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

// MARK: - 基础图形

/// macOS 图标的底：系统图标网格里那个连续曲率的圆角方块。
/// 形状必须和系统的一致——系统靠轮廓认出一个图标有没有自带合规的底板，
/// 角画得圆一点，它就把整个图标当成「内容」缩进一个灰色底板里。
/// 控制点取自系统形状（边长归一化到 100，坐标原点在左下）
func squircle(_ rect: CGRect) -> CGPath {
    let x0 = rect.minX, y0 = rect.minY, w = rect.width, h = rect.height
    func p(_ a: CGFloat, _ b: CGFloat) -> CGPoint { CGPoint(x: x0 + a / 100 * w, y: y0 + b / 100 * h) }
    let path = CGMutablePath()
    path.move(to: p(50, 100))
    path.addCurve(to: p(94.7, 94.7), control1: p(78.6, 100), control2: p(89.4, 100))
    path.addCurve(to: p(100, 50), control1: p(100, 89.4), control2: p(100, 78.6))
    path.addCurve(to: p(94.7, 5.3), control1: p(100, 21.4), control2: p(100, 10.6))
    path.addCurve(to: p(50, 0), control1: p(89.4, 0), control2: p(78.6, 0))
    path.addCurve(to: p(5.3, 5.3), control1: p(21.4, 0), control2: p(10.6, 0))
    path.addCurve(to: p(0, 50), control1: p(0, 10.6), control2: p(0, 21.4))
    path.addCurve(to: p(5.3, 94.7), control1: p(0, 78.6), control2: p(0, 89.4))
    path.addCurve(to: p(50, 100), control1: p(10.6, 100), control2: p(21.4, 100))
    path.closeSubpath()
    return path
}

/// 一条圆头的横线
func line(_ x1: CGFloat, _ y: CGFloat, _ x2: CGFloat, _ width: CGFloat, color: CGColor, in ctx: CGContext) {
    let half = width / 2
    ctx.addPath(CGPath(roundedRect: CGRect(x: x1, y: y - half, width: x2 - x1, height: width),
                       cornerWidth: half, cornerHeight: half, transform: nil))
    ctx.setFillColor(color)
    ctx.fillPath()
}

func dot(_ x: CGFloat, _ y: CGFloat, _ diameter: CGFloat, color: CGColor, in ctx: CGContext) {
    ctx.setFillColor(color)
    ctx.fillEllipse(in: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
}

/// 三个角都是圆的三角形（气泡的尾巴）
func roundedTriangle(_ p: [CGPoint], radius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    func towards(_ from: CGPoint, _ to: CGPoint, _ d: CGFloat) -> CGPoint {
        let len = hypot(to.x - from.x, to.y - from.y)
        guard len > 0 else { return from }
        return CGPoint(x: from.x + (to.x - from.x) / len * d, y: from.y + (to.y - from.y) / len * d)
    }
    for i in 0..<3 {
        let a = p[i], prev = p[(i + 2) % 3], next = p[(i + 1) % 3]
        let enter = towards(a, prev, r), leave = towards(a, next, r)
        if i == 0 { path.move(to: leave) } else { path.addLine(to: enter); path.addQuadCurve(to: leave, control: a) }
    }
    path.closeSubpath()
    return path
}

/// 几何画法的花括号：线宽均匀、圆头，和它中间的线条是同一种笔。
/// 局部坐标里尖在原点，两个端点在 (w, ±h/2)；mirrored 为 true 时是右花括号
func bracePath(width w: CGFloat, height h: CGFloat, mirrored: Bool) -> CGPath {
    let p = CGMutablePath()
    let k = mirrored ? -1.0 : 1.0
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y) }
    let half = h / 2
    // 上半：从端点先向左弯下来，再向左凸出到中间的尖；下半是它的镜像
    p.move(to: pt(w, half))
    p.addCurve(to: pt(0.36 * w, 0.22 * h), control1: pt(0.30 * w, half), control2: pt(0.36 * w, 0.36 * h))
    p.addCurve(to: pt(0, 0), control1: pt(0.36 * w, 0.12 * h), control2: pt(0.16 * w, 0.08 * h))
    p.addCurve(to: pt(0.36 * w, -0.22 * h), control1: pt(0.16 * w, -0.08 * h), control2: pt(0.36 * w, -0.12 * h))
    p.addCurve(to: pt(w, -half), control1: pt(0.36 * w, -0.36 * h), control2: pt(0.30 * w, -half))
    return p
}

func drawBraces(tipInset: CGFloat, width w: CGFloat, height h: CGFloat, lineWidth: CGFloat,
                color: CGColor, in ctx: CGContext, rect: CGRect) {
    ctx.saveGState()
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(color)
    for mirrored in [false, true] {
        let tipX = mirrored ? rect.maxX - tipInset : rect.minX + tipInset
        ctx.saveGState()
        ctx.translateBy(x: tipX, y: rect.midY)
        ctx.addPath(bracePath(width: w, height: h, mirrored: mirrored))
        ctx.strokePath()
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

// MARK: - 图标本体

/// 在 size×size 像素的透明画布上画图标
func render(design: Design, palette: Palette, size px: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(px), height: Int(px), bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let u = px / 1024
    // 小尺寸占满一些画布、少一些细节，否则缩到 16 像素就什么都看不见了
    let body: CGFloat = px >= 128 ? 824 : (px >= 64 ? 888 : 960)
    let tiny = px < 64
    let rect = CGRect(x: (px - body * u) / 2, y: (px - body * u) / 2, width: body * u, height: body * u)
    let shape = squircle(rect)

    // 投影（小尺寸不画）
    if px >= 128 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -28 * u), blur: 46 * u, color: rgb(0x00_00_00, 0.16))
        ctx.setFillColor(palette.bottom)
        ctx.addPath(shape)
        ctx.fillPath()
        ctx.restoreGState()
    }
    // 底：渐变，顶部带一点光
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: srgb(), colors: [palette.top, palette.bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    let glow = CGGradient(colorsSpace: srgb(), colors: [palette.glow, rgb(0xFF_FF_FF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: rect.midX, y: rect.maxY * 0.98), startRadius: 0,
                           endCenter: CGPoint(x: rect.midX, y: rect.maxY * 0.98), endRadius: rect.width * 0.78, options: [])
    ctx.restoreGState()
    // 内侧一圈细高光，上亮下暗
    let inner = squircle(rect.insetBy(dx: 2.6 * u, dy: 2.6 * u))
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.addPath(inner)
    ctx.clip(using: .evenOdd)
    let rim = CGGradient(colorsSpace: srgb(), colors: [rgb(0xFF_FF_FF, 0.26), rgb(0xFF_FF_FF, 0.02)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(rim, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.restoreGState()

    let cx = rect.midX, cy = rect.midY
    let white = rgb(0xFF_FF_FF, 0.96)
    let braceWidth: CGFloat = tiny ? max(34 * u, 1.4) : 34 * u
    let strokeWidth: CGFloat = tiny ? max(30 * u, 1.5) : 27 * u

    switch design {
    case .bracesBubble:
        drawBraces(tipInset: rect.width * 0.112, width: rect.width * 0.168, height: rect.width * 0.62,
                   lineWidth: braceWidth, color: white, in: ctx, rect: rect)
        // 气泡居中放在两个花括号之间，尾巴朝左下
        let bw = rect.width * (tiny ? 0.38 : 0.355), bh = rect.width * 0.262
        let bx = cx - bw / 2, by = cy - bh / 2 + rect.width * 0.012
        ctx.setFillColor(bubbleGreen)
        ctx.addPath(roundedTriangle([CGPoint(x: bx + bw * 0.27, y: by + bh * 0.12),
                                     CGPoint(x: bx + bw * 0.45, y: by + bh * 0.02),
                                     CGPoint(x: bx + bw * 0.21, y: by - bh * 0.40)], radius: 10 * u))
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: CGRect(x: bx, y: by, width: bw, height: bh),
                           cornerWidth: bh * 0.32, cornerHeight: bh * 0.32, transform: nil))
        ctx.fillPath()
        if !tiny {
            // 气泡里的两行字
            let lw = max(bh * 0.115, 1)
            for (i, len) in [0.54, 0.36].enumerated() {
                line(bx + bw * 0.23, by + bh * (0.615 - 0.25 * CGFloat(i)), bx + bw * 0.23 + bw * CGFloat(len), lw,
                     color: palette.bottom, in: ctx)
            }
        }

    case .bracesDots, .bracesLines:
        drawBraces(tipInset: rect.width * 0.145, width: rect.width * 0.165, height: rect.width * 0.575,
                   lineWidth: braceWidth, color: white, in: ctx, rect: rect)
        let left = rect.minX + rect.width * 0.355, right = rect.maxX - rect.width * 0.355
        let span = right - left
        let gap = rect.width * 0.132
        let ink = rgb(0xFF_FF_FF, px < 128 ? 0.96 : 0.84)
        let colors = [dotColors.0, dotColors.1, dotColors.2]
        if design == .bracesDots {
            let dotD = max(29 * u, strokeWidth * (px <= 64 ? 1.5 : 1.2))
            if px <= 64 {
                // 最小的两档看不清键和冒号：只留「点 + 值」
                let dotX = left + dotD / 2
                for (i, color) in colors.enumerated() {
                    let y = cy + gap * CGFloat(1 - i)
                    dot(dotX, y, dotD, color: color, in: ctx)
                    line(dotX + dotD / 2 + span * 0.09, y, left + span * [0.78, 0.64, 0.50][i], strokeWidth, color: ink, in: ctx)
                }
            } else {
                let keyLen = span * 0.27, valueLens = [0.43, 0.34, 0.25]
                let dotX = left + keyLen + span * 0.115
                for (i, color) in colors.enumerated() {
                    let y = cy + gap * CGFloat(1 - i)
                    line(left, y, left + keyLen, strokeWidth, color: ink, in: ctx)
                    dot(dotX, y, dotD, color: color, in: ctx)
                    line(dotX + span * 0.115, y, dotX + span * 0.115 + span * CGFloat(valueLens[i]), strokeWidth, color: ink, in: ctx)
                }
            }
        } else {
            for (i, color) in colors.enumerated() {
                let y = cy + gap * CGFloat(1 - i)
                line(left, y, left + span * [1.0, 0.78, 0.58][i], strokeWidth, color: color, in: ctx)
            }
        }
    }
    return ctx.makeImage()!
}

// MARK: - 输出

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MakeIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG 编码失败：\(url.path)"])
    }
    try data.write(to: url)
}

func label(_ s: String, size: CGFloat, color: CGColor, at p: CGPoint, in ctx: CGContext) {
    let font = NSFont.systemFont(ofSize: size, weight: .medium) as CTFont
    let str = CFAttributedStringCreate(nil, s as CFString, [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary)!
    ctx.saveGState()
    ctx.textPosition = p
    CTLineDraw(CTLineCreateWithAttributedString(str), ctx)
    ctx.restoreGState()
}

func bitmapContext(width: CGFloat, height: CGFloat) -> CGContext {
    CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
              space: srgb(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// 预览图：上半深色背景、下半浅色背景，各放一张大图和 128 / 64 / 32 / 16 像素的原大
func preview(design: Design, palette: Palette, to url: URL) throws {
    let width: CGFloat = 900, half: CGFloat = 330
    let ctx = bitmapContext(width: width, height: half * 2)
    let big: CGFloat = 256
    let sizes: [CGFloat] = [128, 64, 32, 16]
    for (row, bg) in [rgb(0xEC_ED_F0), rgb(0x24_24_27)].enumerated() {
        let y0 = half * CGFloat(row)
        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: 0, y: y0, width: width, height: half))
        let textColor = row == 0 ? rgb(0x3A_3A_40) : rgb(0xDE_DE_E4)
        let base = y0 + 64
        var x: CGFloat = 40
        ctx.draw(render(design: design, palette: palette, size: big), in: CGRect(x: x, y: base, width: big, height: big))
        x += big + 60
        // 小尺寸底边对齐、各自标上像素数
        for px in sizes {
            ctx.draw(render(design: design, palette: palette, size: px), in: CGRect(x: x, y: base + 34, width: px, height: px))
            label("\(Int(px))", size: 13, color: textColor, at: CGPoint(x: x, y: base - 4), in: ctx)
            x += px + 46
        }
    }
    try writePNG(ctx.makeImage()!, to: url)
}

/// 对比图：每行一种配色，每列一种构图；大图旁边是 64 / 32 像素的原大
func compare(designs: [Design], palettes: [Palette], to url: URL) throws {
    let cell: CGFloat = 300, rowH: CGFloat = 330
    let ctx = bitmapContext(width: cell * CGFloat(designs.count), height: rowH * CGFloat(palettes.count))
    ctx.setFillColor(rgb(0x24_24_27))
    ctx.fill(CGRect(x: 0, y: 0, width: cell * CGFloat(designs.count), height: rowH * CGFloat(palettes.count)))
    for (r, pal) in palettes.enumerated() {
        for (c, d) in designs.enumerated() {
            let x = cell * CGFloat(c), y = rowH * CGFloat(palettes.count - 1 - r)
            let big: CGFloat = 236
            ctx.draw(render(design: d, palette: pal, size: big), in: CGRect(x: x + 22, y: y + rowH - big - 26, width: big, height: big))
            ctx.interpolationQuality = .none
            var sx = x + cell - 110
            for (px, scale) in [(CGFloat(64), CGFloat(1)), (32, 2)] {
                ctx.draw(render(design: d, palette: pal, size: px), in: CGRect(x: sx, y: y + 42, width: px * scale, height: px * scale))
                sx += px * scale + 12
            }
            label("\(d.rawValue) · \(pal.rawValue)", size: 14, color: rgb(0xB8_B8_C0), at: CGPoint(x: x + 22, y: y + 8), in: ctx)
        }
    }
    try writePNG(ctx.makeImage()!, to: url)
}

func build(design: Design, palette: Palette, to outDir: URL) throws {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    // iconutil 要求的十个尺寸，文件名是约定好的
    let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    let specs = [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
                 (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"),
                 (512, "icon_512x512"), (1024, "icon_512x512@2x")]
    for (px, name) in specs {
        try writePNG(render(design: design, palette: palette, size: CGFloat(px)), to: iconset.appendingPathComponent("\(name).png"))
    }
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw NSError(domain: "MakeIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "iconutil 生成 icns 失败"])
    }
    try FileManager.default.removeItem(at: iconset)

    try writePNG(render(design: design, palette: palette, size: 1024), to: outDir.appendingPathComponent("AppIcon.png"))
    try preview(design: design, palette: palette, to: outDir.appendingPathComponent("AppIcon-preview.png"))
    print("已生成 \(design.rawValue) · \(palette.rawValue)：\(outDir.path)/AppIcon.{icns,png} 与 AppIcon-preview.png")
}

switch args.count > 1 ? args[1] : "" {
case "build":
    let design = Design(rawValue: args.count > 2 ? args[2] : "") ?? defaultDesign
    let palette = Palette(rawValue: args.count > 3 ? args[3] : "") ?? defaultPalette
    let outDir = URL(fileURLWithPath: args.count > 4 ? args[4] : "Resources", isDirectory: true)
    try build(design: design, palette: palette, to: outDir)
case "compare":
    guard args.count > 2 else { print("用法: MakeIcon.swift compare <输出.png>"); exit(2) }
    try compare(designs: Design.allCases, palettes: Palette.allCases, to: URL(fileURLWithPath: args[2]))
    print("已生成对比图：\(args[2])")
default:
    print("""
    用法:
      swift Scripts/MakeIcon.swift build [构图] [配色] [输出目录]   生成 AppIcon.icns / .png 和预览图
      swift Scripts/MakeIcon.swift compare <输出.png>                几种构图和配色的对比图
    构图: \(Design.allCases.map(\.rawValue).joined(separator: ", "))
    配色: \(Palette.allCases.map(\.rawValue).joined(separator: ", "))
    """)
    exit(args.count > 1 ? 2 : 0)
}
