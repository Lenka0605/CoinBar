import AppKit
import ImageIO

// 将 image_gen 生成的源图归一到项目约定的 macOS 图标网格。
// 用法：swift scripts/assets/make-app-icon.swift Resources/AppIcon-1024.png
// 源图和提示词放在本脚本旁边；不生成 icns，定稿后由打包流程生成。
let scriptURL = URL(fileURLWithPath: #filePath)
let sourceURL = scriptURL.deletingLastPathComponent().appendingPathComponent("coinbar-icon-source.png")
let destination = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon-1024.png"
guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let source = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    fatalError("无法读取源图：\(sourceURL.path)")
}
let width = source.width, height = source.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let sourceBounds: CGRect = pixels.withUnsafeMutableBytes { storage in
    guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("无法创建图像上下文")
    }
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    func alpha(_ x: Int, _ y: Int) -> UInt8 { storage[(y * width + x) * 4 + 3] }
    // 中心轴上主底板完全不透明，忽略生成器在外围留下的半透明碎边。
    let horizontal = (0..<width).filter { alpha($0, height / 2) >= 250 }
    let vertical = (0..<height).filter { alpha(width / 2, $0) >= 250 }
    guard let left = horizontal.first, let right = horizontal.last,
          let bottom = vertical.first, let top = vertical.last else { fatalError("源图没有不透明主体") }
    return CGRect(x: left, y: bottom, width: right - left + 1, height: top - bottom + 1)
}

guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("无法创建输出画布") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let context = graphics.cgContext
context.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
context.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
context.clip()
context.interpolationQuality = .high
let scaleX = body.width / sourceBounds.width
let scaleY = body.height / sourceBounds.height
context.translateBy(x: body.minX - sourceBounds.minX * scaleX, y: body.minY - sourceBounds.minY * scaleY)
context.scaleBy(x: scaleX, y: scaleY)
context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG 编码失败") }
try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
print("已生成：\(destination)；1024×1024 RGBA，主体 824×824，边距 100，圆角 185")
