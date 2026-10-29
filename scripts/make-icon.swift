#!/usr/bin/env swift
//
// StorageLens 앱 아이콘 생성기. 사용: swift scripts/make-icon.swift [출력 icns 경로] [512px 미리보기 PNG 경로]
// 기본 출력: Resources/AppIcon.icns. 선버스트(동심 원호) 모티프, 텍스트 없음.
//
import AppKit
import CoreGraphics

let fm = FileManager.default
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let args = Array(CommandLine.arguments.dropFirst())
let icnsURL = URL(fileURLWithPath: args.first ?? scriptDir.appendingPathComponent("../Resources/AppIcon.icns").path).standardized
let previewURL = args.count > 1 ? URL(fileURLWithPath: args[1]) : nil

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}
func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

func drawIcon(_ ctx: CGContext) {
    let S: CGFloat = 1024
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 824 * 0.2237, cornerHeight: 824 * 0.2237, transform: nil)
    let center = CGPoint(x: S / 2, y: S / 2)

    // 본체 그림자
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(squircle); ctx.setFillColor(rgb(0.05, 0.1, 0.25)); ctx.fillPath()
    ctx.restoreGState()

    // 본체: 깊은 블루 -> 인디고 그라데이션
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0.02, 0.07, 0.22)), (0.55, rgb(0.04, 0.2, 0.46)), (1, rgb(0.06, 0.34, 0.62))]),
                           start: CGPoint(x: S / 2, y: body.minY), end: CGPoint(x: S / 2, y: body.maxY), options: [])
    // 중앙 글로우
    ctx.drawRadialGradient(gradient([(0, rgb(0.2, 0.75, 0.85, 0.45)), (1, rgb(0.2, 0.75, 0.85, 0))]),
                           startCenter: center, startRadius: 0, endCenter: center, endRadius: 400, options: [])

    // 동심 원호 3층 (바깥 -> 안쪽): 각 층은 세그먼트로 끊긴 두꺼운 호
    struct Ring { let r: CGFloat; let w: CGFloat; let start: CGFloat; let sweep: CGFloat
                  let c1: CGColor; let c2: CGColor }
    let rings = [
        Ring(r: 330, w: 56, start: 200, sweep: 300, c1: rgb(0.25, 0.55, 1.0), c2: rgb(0.2, 0.85, 0.9)),
        Ring(r: 245, w: 56, start: 150, sweep: 260, c1: rgb(0.3, 0.7, 1.0), c2: rgb(0.35, 0.95, 0.88)),
        Ring(r: 160, w: 56, start: 100, sweep: 220, c1: rgb(0.4, 0.8, 1.0), c2: rgb(0.55, 1.0, 0.9)),
    ]
    for ring in rings {
        let a0 = ring.start * .pi / 180, a1 = (ring.start + ring.sweep) * .pi / 180
        let arc = CGMutablePath()
        arc.addArc(center: center, radius: ring.r, startAngle: a0, endAngle: a1, clockwise: false)
        let stroked = arc.copy(strokingWithWidth: ring.w, lineCap: .round, lineJoin: .round, miterLimit: 10)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0, 0.05, 0.2, 0.5))
        ctx.addPath(stroked); ctx.setFillColor(ring.c1); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(stroked); ctx.clip()
        let bb = stroked.boundingBox
        ctx.drawLinearGradient(gradient([(0, ring.c1), (1, ring.c2)]),
                               start: CGPoint(x: bb.minX, y: bb.maxY), end: CGPoint(x: bb.maxX, y: bb.minY), options: [])
        // 상단 하이라이트
        ctx.drawLinearGradient(gradient([(0, rgb(1, 1, 1, 0.45)), (0.5, rgb(1, 1, 1, 0.05)), (1, rgb(1, 1, 1, 0))]),
                               start: CGPoint(x: 0, y: bb.maxY), end: CGPoint(x: 0, y: bb.midY), options: [])
        ctx.restoreGState()
        // 얇은 밝은 테두리
        ctx.saveGState()
        ctx.addPath(stroked); ctx.setStrokeColor(rgb(1, 1, 1, 0.35)); ctx.setLineWidth(2); ctx.strokePath()
        ctx.restoreGState()
    }

    // 중앙 원
    let core = CGRect(x: center.x - 62, y: center.y - 62, width: 124, height: 124)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0, 0.05, 0.2, 0.5))
    ctx.setFillColor(rgb(0.6, 0.95, 1)); ctx.fillEllipse(in: core)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: core); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0.3, 0.8, 0.95)), (1, rgb(0.85, 1, 1))]),
                           start: CGPoint(x: core.minX, y: core.minY), end: CGPoint(x: core.maxX, y: core.maxY), options: [])
    ctx.drawLinearGradient(gradient([(0, rgb(1, 1, 1, 0.7)), (1, rgb(1, 1, 1, 0))]),
                           start: CGPoint(x: 0, y: core.maxY), end: CGPoint(x: 0, y: core.midY), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(rgb(1, 1, 1, 0.5)); ctx.setLineWidth(2); ctx.strokeEllipse(in: core)

    // 본체 상단 글래스 하이라이트
    ctx.drawLinearGradient(gradient([(0, rgb(1, 1, 1, 0.22)), (1, rgb(1, 1, 1, 0))]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.maxY - 300), options: [])
    ctx.restoreGState()

    // 본체 테두리 (위쪽 밝게, 아래쪽 어둡게)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(1, 1, 1, 0.1)), (1, rgb(1, 1, 1, 0.55))]),
                           start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let tmp = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmp) }
for base in [16, 32, 128, 256, 512] {
    try render(pixels: base).write(to: tmp.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(pixels: base * 2).write(to: tmp.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if let previewURL {
    try fm.createDirectory(at: previewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.copyItem(at: tmp.appendingPathComponent("icon_512x512.png"), to: previewURL)
}
try fm.createDirectory(at: icnsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", icnsURL.path]
try p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else { fputs("error: iconutil failed\n", stderr); exit(1) }
print("wrote \(icnsURL.path)")
