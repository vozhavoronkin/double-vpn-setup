#!/usr/bin/env swift
import AppKit

// Рисует иконку приложения 1024×1024: тёмно-синий градиент, щит и звено цепи.
// Детерминированный шаг без сетевых зависимостей: `swift scripts/make-app-icon.swift <out.png>`.

let size = 1024
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon_1024.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("не удалось создать битмап")
}

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("не удалось создать графический контекст")
}
NSGraphicsContext.current = context

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
let shape = NSBezierPath(roundedRect: canvas, xRadius: 190, yRadius: 190)

// Фон: тёмно-синий → индиго.
let background = NSGradient(
    starting: NSColor(srgbRed: 0.09, green: 0.13, blue: 0.31, alpha: 1),
    ending: NSColor(srgbRed: 0.27, green: 0.19, blue: 0.56, alpha: 1)
)
background?.draw(in: shape, angle: -70)

// Верхний блик.
shape.addClip()
let sheen = NSGradient(
    starting: NSColor(white: 1, alpha: 0.10),
    ending: NSColor(white: 1, alpha: 0)
)
sheen?.draw(
    in: NSRect(x: 0, y: CGFloat(size) * 0.45, width: CGFloat(size), height: CGFloat(size) * 0.55),
    angle: -90
)

// Щит.
let cx: CGFloat = 512
let top: CGFloat = 806
let shoulder: CGFloat = 608
let bottom: CGFloat = 236
let half: CGFloat = 252

let shield = NSBezierPath()
shield.move(to: NSPoint(x: cx - half, y: top))
shield.line(to: NSPoint(x: cx - half, y: shoulder))
shield.curve(
    to: NSPoint(x: cx, y: bottom),
    controlPoint1: NSPoint(x: cx - half, y: bottom + 150),
    controlPoint2: NSPoint(x: cx - 118, y: bottom + 58)
)
shield.curve(
    to: NSPoint(x: cx + half, y: shoulder),
    controlPoint1: NSPoint(x: cx + 118, y: bottom + 58),
    controlPoint2: NSPoint(x: cx + half, y: bottom + 150)
)
shield.line(to: NSPoint(x: cx + half, y: top))
shield.close()

NSColor(srgbRed: 0.98, green: 0.99, blue: 1, alpha: 0.96).setStroke()
shield.lineWidth = 30
shield.lineJoinStyle = .round
shield.stroke()

// Звено цепи: два переплетённых кольца внутри щита.
let ringRadius: CGFloat = 104
let ringOffset: CGFloat = 66
let ringY: CGFloat = 552
for sign in [1.0, -1.0] {
    let center = NSPoint(x: cx + CGFloat(sign) * ringOffset, y: ringY)
    let ring = NSBezierPath(
        ovalIn: NSRect(
            x: center.x - ringRadius,
            y: center.y - ringRadius,
            width: ringRadius * 2,
            height: ringRadius * 2
        )
    )
    NSColor(srgbRed: 0.98, green: 0.99, blue: 1, alpha: 0.96).setStroke()
    ring.lineWidth = 26
    ring.stroke()
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("не удалось закодировать PNG")
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("иконка записана: \(outputPath)")
