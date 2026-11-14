#!/usr/bin/env swift
// MyTerminal 앱 아이콘을 크기별 PNG 로 그려 AppIcon.appiconset 에 넣는다.
// 사용법: swift scripts/make-app-icon.swift Resources/Assets.xcassets/AppIcon.appiconset
//
// 디자인: macOS 아이콘 격자(1024 캔버스, 824 둥근 사각형) 위에
//   남색 그라데이션 바탕 + 파란 프롬프트 기호(>) + 밝은 커서(_)
// 다른 제품의 아이콘·색을 따라 하지 않은 MyTerminal 고유 디자인이다.

import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// 1024 기준 좌표로 그리고 size 에 맞게 줄인다 (크기마다 벡터로 다시 그려 선명하게).
func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    // 몸체: 824×824 둥근 사각형 (macOS 아이콘 격자), 아래쪽에 옅은 그림자
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let corner: CGFloat = 186
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    color(0x161925).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 바탕: 위가 조금 밝은 남색 그라데이션
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    NSGradient(colors: [color(0x2C3452), color(0x1A1E2E), color(0x12141E)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: body, angle: -90)

    // 위쪽 은은한 빛 (유리 느낌 없이 아주 약하게)
    NSGradient(colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)])!
        .draw(in: CGRect(x: body.minX, y: body.midY + 120, width: body.width, height: body.height / 2 - 120), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // 가장자리 얇은 테두리
    color(0xFFFFFF, 0.08).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 3, dy: 3), xRadius: corner - 3, yRadius: corner - 3)
    rim.lineWidth = 6
    rim.stroke()

    // 프롬프트 기호 ">" : 파란 그라데이션, 굵고 둥근 끝
    let chevron = NSBezierPath()
    chevron.move(to: CGPoint(x: 300, y: 650))
    chevron.line(to: CGPoint(x: 490, y: 512))
    chevron.line(to: CGPoint(x: 300, y: 374))
    chevron.lineWidth = 86
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round

    NSGraphicsContext.saveGraphicsState()
    let chevronOutline = chevron.cgPathStroked()
    cg.addPath(chevronOutline)
    cg.clip()
    NSGradient(colors: [color(0x8DB4FF), color(0x5B8DEF), color(0x3D6FD8)])!
        .draw(in: CGRect(x: 240, y: 320, width: 320, height: 390), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // 커서 "_" : 밝은 회백색 둥근 막대
    let cursor = NSBezierPath(roundedRect: CGRect(x: 548, y: 330, width: 196, height: 78), xRadius: 39, yRadius: 39)
    color(0xE6E8F0).setFill()
    cursor.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

extension NSBezierPath {
    /// 선 모양을 채울 수 있는 외곽선 경로로 바꾼다 (그라데이션을 선에 칠하기 위해)
    func cgPathStroked() -> CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &points) {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }
}

// macOS 아이콘 크기: 16, 32, 128, 256, 512 의 1x·2x
let specs: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
var images: [[String: String]] = []
for spec in specs {
    let pixels = spec.points * spec.scale
    let name = "icon_\(spec.points)x\(spec.points)\(spec.scale == 2 ? "@2x" : "").png"
    try render(size: pixels).write(to: outputDirectory.appendingPathComponent(name))
    images.append([
        "filename": name,
        "idiom": "mac",
        "scale": "\(spec.scale)x",
        "size": "\(spec.points)x\(spec.points)",
    ])
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))

// 상위 Assets.xcassets 의 Contents.json
let catalog = outputDirectory.deletingLastPathComponent()
try #"{"info":{"author":"xcode","version":1}}"#.write(
    to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

print("완료: \(outputDirectory.path) (\(specs.count)개)")
