import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S), flipped: false) { _ in
    let ctx = NSGraphicsContext.current!.cgContext
    // macOS 图标网格：主体 824x824，居中，圆角 ~185
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // 投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); shape.fill()
    ctx.restoreGState()

    // 背景：深夜蓝 → 靛紫
    shape.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.07, green: 0.09, blue: 0.20, alpha: 1),
                        NSColor(srgbRed: 0.20, green: 0.11, blue: 0.42, alpha: 1)])!
        .draw(in: body, angle: 60)

    // 顶部一条「菜单栏」
    let bar = CGRect(x: 100, y: 924 - 120, width: 824, height: 120)
    NSColor.white.withAlphaComponent(0.08).setFill(); NSBezierPath(rect: bar).fill()
    let dots: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
    for (i, c) in dots.enumerated() {
        c.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: CGRect(x: 170 + CGFloat(i) * 56, y: bar.midY - 18, width: 36, height: 36)).fill()
    }
    // 菜单栏里的价格胶囊
    let pill = CGRect(x: 560, y: bar.midY - 34, width: 300, height: 68)
    NSColor(srgbRed: 0.20, green: 0.85, blue: 0.55, alpha: 0.95).setFill()
    NSBezierPath(roundedRect: pill, xRadius: 34, yRadius: 34).fill()
    let up = NSBezierPath()
    up.move(to: CGPoint(x: pill.minX + 44, y: pill.midY - 14))
    up.line(to: CGPoint(x: pill.minX + 66, y: pill.midY + 16))
    up.line(to: CGPoint(x: pill.minX + 88, y: pill.midY - 14))
    up.close()
    NSColor(srgbRed: 0.05, green: 0.25, blue: 0.15, alpha: 1).setFill(); up.fill()
    NSColor(srgbRed: 0.05, green: 0.25, blue: 0.15, alpha: 1).setFill()
    for i in 0..<3 {
        NSBezierPath(roundedRect: CGRect(x: pill.minX + 118 + CGFloat(i) * 46, y: pill.midY - 12, width: 32, height: 24),
                     xRadius: 8, yRadius: 8).fill()
    }

    // 网格线
    NSColor.white.withAlphaComponent(0.06).setStroke()
    for i in 1...4 {
        let y = 160 + CGFloat(i) * 120
        let l = NSBezierPath(); l.move(to: CGPoint(x: 160, y: y)); l.line(to: CGPoint(x: 864, y: y)); l.lineWidth = 3; l.stroke()
    }

    // K 线
    let green = NSColor(srgbRed: 0.20, green: 0.85, blue: 0.55, alpha: 1)
    let red = NSColor(srgbRed: 0.98, green: 0.36, blue: 0.40, alpha: 1)
    let candles: [(x: CGFloat, lo: CGFloat, o: CGFloat, c: CGFloat, hi: CGFloat)] = [
        (215, 230, 260, 360, 400), (330, 300, 380, 320, 420), (445, 300, 330, 470, 510),
        (560, 420, 460, 430, 520), (675, 410, 440, 590, 630),
    ]
    for k in candles {
        let col = k.c >= k.o ? green : red
        col.setFill(); col.setStroke()
        let wick = NSBezierPath(); wick.move(to: CGPoint(x: k.x, y: k.lo)); wick.line(to: CGPoint(x: k.x, y: k.hi))
        wick.lineWidth = 12; wick.lineCapStyle = .round; wick.stroke()
        NSBezierPath(roundedRect: CGRect(x: k.x - 34, y: min(k.o, k.c), width: 68, height: abs(k.c - k.o)), xRadius: 10, yRadius: 10).fill()
    }

    // 上涨趋势线 + 光晕
    let trend = NSBezierPath()
    trend.move(to: CGPoint(x: 170, y: 250))
    trend.curve(to: CGPoint(x: 500, y: 440), controlPoint1: CGPoint(x: 300, y: 260), controlPoint2: CGPoint(x: 380, y: 450))
    trend.curve(to: CGPoint(x: 770, y: 640), controlPoint1: CGPoint(x: 620, y: 430), controlPoint2: CGPoint(x: 680, y: 640))
    trend.lineWidth = 22; trend.lineCapStyle = .round; trend.lineJoinStyle = .round
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: NSColor(srgbRed: 1, green: 0.8, blue: 0.3, alpha: 0.9).cgColor)
    NSColor(srgbRed: 1.0, green: 0.80, blue: 0.30, alpha: 1).setStroke(); trend.stroke()
    ctx.restoreGState()

    // 金币
    let coin = CGRect(x: 690, y: 560, width: 170, height: 170)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    NSGradient(colors: [NSColor(srgbRed: 1.0, green: 0.86, blue: 0.40, alpha: 1),
                        NSColor(srgbRed: 0.93, green: 0.60, blue: 0.10, alpha: 1)])!
        .draw(in: NSBezierPath(ovalIn: coin), angle: -60)
    ctx.restoreGState()
    NSColor(srgbRed: 1, green: 0.95, blue: 0.75, alpha: 0.8).setStroke()
    let rim = NSBezierPath(ovalIn: coin.insetBy(dx: 16, dy: 16)); rim.lineWidth = 6; rim.stroke()
    let sym = NSAttributedString(string: "$", attributes: [
        .font: NSFont.systemFont(ofSize: 104, weight: .heavy),
        .foregroundColor: NSColor(srgbRed: 0.55, green: 0.32, blue: 0.02, alpha: 1)])
    let sz = sym.size()
    sym.draw(at: CGPoint(x: coin.midX - sz.width / 2, y: coin.midY - sz.height / 2 + 2))

    // 高光
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: 100, y: 512, width: 824, height: 412), angle: -90)
    return true
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
