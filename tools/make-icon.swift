// Generates AppIcon.iconset for dsh-mac.
//
// Classic DeepSeek mark: the blue whale, drawn as vectors at every required
// size rather than downscaled from one bitmap, so small sizes stay sharp. The
// shape follows Apple's macOS icon grid — the rounded-square content area is
// inset and the corners are generous, matching the system icons it sits beside.
//
// The whale outline is parsed from DeepSeek Harness's own frontend asset
// (`tools/deepseek-whale.path`, the path data of the shipped favicon) rather
// than redrawn by hand, so the mark is the real one.
//
// Usage: swiftc -O -o make-icon tools/make-icon.swift
//        ./make-icon <output.iconset> <whale.path>

import AppKit
import Foundation

/// The artwork is authored in a 1024x1024 space and scaled to each target size.
private let canvas: CGFloat = 1024

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

// MARK: - SVG path data

/// Minimal reader for the subset of SVG path syntax the whale uses: absolute
/// `M`, cubic `C`, and `Z`. Anything else is ignored rather than guessed at,
/// so an unexpected asset fails visibly (an empty icon) instead of silently
/// drawing something wrong.
///
/// `map` converts a point from the asset's coordinate space (y-down, as SVG
/// defines it) into the AppKit space the icon is drawn in (y-up).
private func parsePathData(_ data: String, map: (Double, Double) -> NSPoint) -> NSBezierPath {
    let path = NSBezierPath()
    path.windingRule = .nonZero

    // Tokenize into (command, operands) groups.
    var groups: [(command: Character, operands: [Double])] = []
    var command: Character?
    var operands: [Double] = []
    let characters = Array(data)
    var index = 0

    while index < characters.count {
        let character = characters[index]

        if character.isLetter {
            if let previous = command { groups.append((previous, operands)) }
            command = character
            operands = []
            index += 1
            continue
        }

        guard character.isNumber || character == "-" || character == "+" || character == "." else {
            index += 1 // whitespace or comma
            continue
        }

        // Scan one number, allowing a leading sign and a decimal point.
        var literal = String(character)
        index += 1
        while index < characters.count {
            let next = characters[index]
            if next.isNumber || next == "." {
                literal.append(next)
                index += 1
            } else if next == "-" || next == "+" {
                // A sign only continues the literal as an exponent, e.g. 1e-5.
                guard let last = literal.last, last == "e" || last == "E" else { break }
                literal.append(next)
                index += 1
            } else {
                break
            }
        }
        operands.append(Double(literal) ?? 0)
    }
    if let previous = command { groups.append((previous, operands)) }

    func point(_ x: Double, _ y: Double) -> NSPoint { map(x, y) }

    for group in groups {
        let values = group.operands
        switch group.command {
        case "M", "m":
            // Absolute only in this asset; extra pairs follow the SVG rule for
            // an implicit lineto.
            var offset = 0
            while offset + 1 < values.count {
                let target = point(values[offset], values[offset + 1])
                if offset == 0 { path.move(to: target) } else { path.line(to: target) }
                offset += 2
            }
        case "C", "c":
            var offset = 0
            while offset + 5 < values.count {
                path.curve(
                    to: point(values[offset + 4], values[offset + 5]),
                    controlPoint1: point(values[offset], values[offset + 1]),
                    controlPoint2: point(values[offset + 2], values[offset + 3]))
                offset += 6
            }
        case "Z", "z":
            path.close()
        default:
            break
        }
    }
    return path
}

/// Rebuild the whale so its bounding box lands exactly on `target`.
///
/// The mapping is done here, one point at a time, instead of through a stack of
/// affine-transform calls: SVG's y axis points down and AppKit's points up, and
/// getting that flip wrong mirrors the whale without failing loudly.
private func whalePath(from data: String, in target: NSRect) -> NSBezierPath {
    // Bounding box of the shipped asset, measured from its start/control points.
    let bounds = (minX: 0.534, maxX: 49.371, minY: 6.944, maxY: 43.576)
    let width = bounds.maxX - bounds.minX
    let height = bounds.maxY - bounds.minY
    let scale = min(target.width / width, target.height / height)

    // Centre the scaled mark inside the target rather than pinning it to a corner.
    let drawn = NSSize(width: width * scale, height: height * scale)
    let left = target.minX + (target.width - drawn.width) / 2
    let bottom = target.minY + (target.height - drawn.height) / 2

    return parsePathData(data) { x, y in
        NSPoint(
            x: left + (x - bounds.minX) * scale,
            // Flip: the asset's lowest y becomes the bottom of the target box.
            y: bottom + (bounds.maxY - y) * scale)
    }
}

// MARK: - Drawing

private func draw(in size: CGFloat, whale: NSBezierPath) {
    let s = size / canvas
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
    }

    // ── the DeepSeek blue field ──────────────────────────────────────────────
    let body = NSBezierPath(
        roundedRect: rect(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    if let gradient = NSGradient(colors: [color(0x5E7BFF), color(0x3D57E8)]) {
        gradient.draw(in: body, angle: -90)
    } else {
        color(0x4D6BFE).setFill()
        body.fill()
    }

    // A soft top highlight keeps the field from reading as flat, matching the
    // lighting of the system icons.
    if let sheen = NSGradient(
        colors: [color(0xFFFFFF, alpha: 0.18), color(0xFFFFFF, alpha: 0)])
    {
        let top = NSBezierPath(
            roundedRect: rect(100, 560, 824, 364), xRadius: 185 * s, yRadius: 185 * s)
        sheen.draw(in: top, angle: -90)
    }

    // ── the whale ────────────────────────────────────────────────────────────
    let mark = whale.copy() as! NSBezierPath
    mark.transform(using: AffineTransform(scale: s))
    color(0xFFFFFF).setFill()
    mark.fill()

    // ── edge ─────────────────────────────────────────────────────────────────
    color(0x000000, alpha: 0.10).setStroke()
    body.lineWidth = max(1, 3 * s)
    body.stroke()
}

/// Renders one PNG at an exact pixel size.
private func png(size: Int, whale: NSBezierPath) -> Data {
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
    else {
        FileHandle.standardError.write(Data("could not allocate a \(size)px bitmap\n".utf8))
        exit(1)
    }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(in: CGFloat(size), whale: whale)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("could not encode the \(size)px image\n".utf8))
        exit(1)
    }
    return data
}

// MARK: - Entry point

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("usage: make-icon <output.iconset> <whale.path>\n".utf8))
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let assetURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let asset = try? String(contentsOf: assetURL, encoding: .utf8),
    !asset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
else {
    FileHandle.standardError.write(Data("could not read path data at \(assetURL.path)\n".utf8))
    exit(1)
}

try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// The whale occupies the middle of the field. It is sized generously so the
// mark still reads at 16pt, where the fine fin and eye details inevitably blur
// into the body — what matters at that size is the silhouette, not the detail.
let whale = whalePath(from: asset, in: NSRect(x: 192, y: 272, width: 640, height: 480))

// Each entry is a rendered pixel size and the iconset names it fills; one size
// serves both the @1x and @2x slot of its neighbours.
let slots: [(pixels: Int, names: [String])] = [
    (16, ["icon_16x16.png"]),
    (32, ["icon_16x16@2x.png", "icon_32x32.png"]),
    (64, ["icon_32x32@2x.png"]),
    (128, ["icon_128x128.png"]),
    (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
    (512, ["icon_256x256@2x.png", "icon_512x512.png"]),
    (1024, ["icon_512x512@2x.png"]),
]

for (pixels, names) in slots {
    let data = png(size: pixels, whale: whale)
    for name in names {
        try data.write(to: output.appendingPathComponent(name))
    }
}

print("wrote \(slots.count) rendered sizes to \(output.path)")
