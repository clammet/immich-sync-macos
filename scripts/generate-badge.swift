import AppKit
import Foundation

// Native vector drawing keeps the badge crisp at Finder's icon sizes.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let folder = root.appendingPathComponent("build/IgnoredBadge.iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
var chunks = Data()
func uint32(_ value: Int) -> Data {
    var value = UInt32(value).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.scaleBy(x: CGFloat(pixels) / 64, y: CGFloat(pixels) / 64)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: 2, y: 2, width: 60, height: 60))
        ctx.setFillColor(NSColor(calibratedWhite: 0.38, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: 6, y: 6, width: 52, height: 52))
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(7); ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 19, y: 19)); ctx.addLine(to: CGPoint(x: 45, y: 45)); ctx.strokePath()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        let types = [16: "icp4", 32: "icp5", 64: "icp6", 128: "ic07", 256: "ic08", 512: "ic09", 1024: "ic10"]
        // One representation per physical pixel size; retina sizes are also represented by larger chunks.
        if scale == 1 || size == 32 || size == 512 {
            chunks.append(Data(types[pixels]!.utf8)); chunks.append(uint32(png.count + 8)); chunks.append(png)
        }
    }
}
try FileManager.default.createDirectory(at: root.appendingPathComponent("Resources"), withIntermediateDirectories: true)
var icon = Data("icns".utf8)
icon.append(uint32(chunks.count + 8)); icon.append(chunks)
try icon.write(to: root.appendingPathComponent("Resources/IgnoredBadge.icns"))
