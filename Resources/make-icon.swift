#!/usr/bin/env swift
//
// AbVoice Local のアプリアイコンを生成する。
//
//   swift Resources/make-icon.swift
//     → Resources/AppIcon.icns を作り直す
//
// 手書きノートのテーマ:
// クリーム紙の下地 + 赤インクの枠 + 少し傾いた「ab」。
// 音声アプリだと分かるよう、下に波形を足している。
//
// ⚠️ ビルドのたびには走らせない（build.sh は生成済みの .icns をコピーするだけ）。
//    デザインを変えたときだけ手で実行して、生成物をコミットする。

import AppKit
import Foundation

// docs/DESIGN_GUIDELINES.md のパレット
let paper = NSColor(srgbRed: 0xFB / 255.0, green: 0xF6 / 255.0, blue: 0xE9 / 255.0, alpha: 1)
let redInk = NSColor(srgbRed: 0xB8 / 255.0, green: 0x3A / 255.0, blue: 0x2A / 255.0, alpha: 1)

/// 1 枚描く。`size` は正方形のピクセル数。
func renderIcon(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.setShouldAntialias(true)

    let s = CGFloat(size)
    /// 1024 基準で設計した値を実サイズに直す。
    func u(_ value: CGFloat) -> CGFloat { value / 1024 * s }

    // 小さいサイズでは波形を入れると潰れるので落とし、その分「ab」を大きくする。
    let showsWaveform = size >= 64

    // --- 下地（角丸の紙）---
    let inset = u(56)
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = u(220)
    let shape = NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner)
    paper.setFill()
    shape.fill()

    // --- 赤インクの枠（favicon の二重丸に合わせて内側にも細い線）---
    redInk.setStroke()
    shape.lineWidth = u(34)
    shape.stroke()

    if size >= 32 {
        let innerInset = u(96)
        let inner = NSRect(
            x: innerInset, y: innerInset,
            width: s - innerInset * 2, height: s - innerInset * 2
        )
        let innerPath = NSBezierPath(
            roundedRect: inner,
            xRadius: corner - u(40), yRadius: corner - u(40)
        )
        innerPath.lineWidth = u(10)
        redInk.withAlphaComponent(0.55).setStroke()
        innerPath.stroke()
    }

    // --- 「ab」---
    let fontSize = showsWaveform ? u(430) : u(520)
    let baselineY = showsWaveform ? u(400) : u(300)

    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
        .foregroundColor: redInk,
        .kern: -u(18),
    ]
    let text = NSAttributedString(string: "ab", attributes: attributes)
    let textSize = text.size()

    NSGraphicsContext.saveGraphicsState()
    // favicon と同じく少しだけ傾ける（手書きノートらしさ）
    let rotation = NSAffineTransform()
    rotation.translateX(by: s / 2, yBy: s / 2)
    rotation.rotate(byDegrees: -3)
    rotation.translateX(by: -s / 2, yBy: -s / 2)
    rotation.concat()
    text.draw(at: NSPoint(x: (s - textSize.width) / 2, y: baselineY))
    NSGraphicsContext.restoreGraphicsState()

    // --- 波形（音声アプリであることを示す）---
    if showsWaveform {
        let heights: [CGFloat] = [90, 190, 300, 190, 90]
        let barWidth = u(52)
        let gap = u(38)
        let totalWidth = barWidth * CGFloat(heights.count) + gap * CGFloat(heights.count - 1)
        var x = (s - totalWidth) / 2
        let centerY = u(288)

        redInk.setFill()
        for height in heights {
            let barHeight = u(height)
            let rect = NSRect(
                x: x, y: centerY - barHeight / 2,
                width: barWidth, height: barHeight
            )
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// --- iconset を書き出して icns にする ---

let resourcesDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/Resources")
let iconsetDir = resourcesDir.appendingPathComponent("AppIcon.iconset")

try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// iconutil が要求する名前と実ピクセル数
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let data = renderIcon(size: variant.pixels) else {
        FileHandle.standardError.write(Data("描画に失敗: \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: iconsetDir.appendingPathComponent("\(variant.name).png"))
}

let icns = resourcesDir.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir.path, "-o", icns.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil が失敗しました\n".utf8))
    exit(1)
}

// 中間生成物は残さない
try? FileManager.default.removeItem(at: iconsetDir)
print("生成: \(icns.path)")
