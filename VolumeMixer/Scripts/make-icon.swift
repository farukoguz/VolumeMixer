#!/usr/bin/env swift
// Draws AppIcon.icns, the application icon.
//
// The icon is generated rather than shipped as a binary blob so that it can be
// reviewed as code and changed deliberately: a designer can alter a colour or a
// proportion here and rebuild, instead of opening a bitmap editor and hoping the
// result matches what was intended.
//
// Shape follows Apple's grid for macOS icons: a 1024px canvas carrying an 824px
// rounded square inset 100px, with a 185px corner radius. The mark is a speaker
// with two arcs, drawn from paths authored on a 24x24 grid. The arcs are laid in
// at descending opacity so the mark reads as sound travelling outward, and stays
// legible when the whole thing is 16px tall in a Dock.
//
// Build:  swift Scripts/make-icon.swift
// Output: Resources/AppIcon.icns
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas = 1024.0
let inset = 100.0
let side = canvas - inset * 2
let radius = side * 0.2246          // 185px, Apple's proportion for this grid
let center = canvas / 2

let outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = outputDirectory.appendingPathComponent("VolumeMixer.iconset")

// MARK: - Palette
// A single blue-to-violet sweep. Two neighbouring hues with a bright midpoint
// read as "audio tooling" without borrowing the look of any particular app, and
// the value range stays narrow so the white mark keeps its contrast at 16px.
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

let gradientColors = [
    rgb(0x1E, 0x6B, 0xFF),   // blue
    rgb(0x5B, 0x45, 0xE8),   // indigo, at the midpoint
    rgb(0xB1, 0x4B, 0xF0),   // violet
] as CFArray

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let gradient = CGGradient(colorsSpace: space, colors: gradientColors, locations: [0, 0.55, 1])
else {
    FileHandle.standardError.write(Data("could not build gradient\n".utf8))
    exit(1)
}

// MARK: - Geometry
/// The rounded square that carries the mark.
func bodyPath() -> CGPath {
    CGPath(roundedRect: CGRect(x: inset, y: inset, width: side, height: side),
           cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// A mark authored on a 24x24 grid, mapped onto the canvas and centred on it.
///
/// Core Graphics draws bottom-up while these paths read top-down, so the vertical
/// axis is flipped rather than the paths being rewritten.
func markPath(_ d: String, visualCenterX: CGFloat = 12, scale: CGFloat) -> CGPath {
    let p = CGMutablePath()

    // The mapping from the 24x24 authoring grid to the canvas is written out by
    // hand rather than assembled from CGAffineTransform calls. Concatenating
    // translate and scale reads as if the order were obvious and is not: the
    // result was an icon whose mark sat above centre. One explicit function makes
    // the intended position checkable by reading it.
    func T(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        // Authored y grows downward, canvas y grows upward.
        CGPoint(x: center + (x - visualCenterX) * scale,
                y: center - (y - 12) * scale)
    }

    // The cursor is kept in authoring coordinates and converted only on the way
    // into the path. Holding a canvas cursor instead meant H and V fed a canvas
    // value back into T, which expects an authored one, and a single "h4" sent
    // the speaker to y = -17865.
    var cx: CGFloat = 0, cy: CGFloat = 0
    var sx: CGFloat = 0, sy: CGFloat = 0
    var lastControl: CGPoint?
    var index = d.startIndex

    // Reads one SVG number. Compact path data writes consecutive numbers with no
    // separator ("c2.89.86", "c.03-.2"), so a number is sign, digits, then at
    // most one dot with digits. Scanning [0-9.] greedily instead swallows both
    // numbers into one unparseable string, Double() returns nil, and every
    // affected control point silently becomes zero.
    func number() -> CGFloat {
        // Path data separates values with whitespace and commas.
        while index < d.endIndex, d[index].isWhitespace || d[index] == "," {
            index = d.index(after: index)
        }
        var text = ""
        if index < d.endIndex, d[index] == "-" || d[index] == "+" {
            text.append(d[index])
            index = d.index(after: index)
        }
        var sawDigit = false
        while index < d.endIndex, d[index].isNumber {
            text.append(d[index])
            sawDigit = true
            index = d.index(after: index)
        }
        if index < d.endIndex, d[index] == "." {
            // Legal with or without leading digits: ".5" and "0.5" both parse.
            text.append(".")
            index = d.index(after: index)
            while index < d.endIndex, d[index].isNumber {
                text.append(d[index])
                sawDigit = true
                index = d.index(after: index)
            }
        }
        guard sawDigit, let value = Double(text) else {
            assertionFailure("unparseable number in path: \(d)")
            return 0
        }
        return CGFloat(value)
    }

    // Every value the parser handles -- including the mirror point derived for a
    // smooth curve -- stays in authoring coordinates. Holding the previous
    // control point in canvas coordinates and subtracting it inside T() is the
    // same class of mistake as the H/V cursor, just one line further down.
    var lastControlX: CGFloat?
    var lastControlY: CGFloat?

    // The commands these marks use: M m L l H h V v C c S s z.
    while index < d.endIndex {
        let command = d[index]
        index = d.index(after: index)
        switch command {
        case "M":
            cx = number(); cy = number()
            p.move(to: T(cx, cy))
            sx = cx; sy = cy
            lastControlX = nil; lastControlY = nil
        case "m":
            cx += number(); cy += number()
            p.move(to: T(cx, cy))
            sx = cx; sy = cy
            lastControlX = nil; lastControlY = nil
        case "L":
            cx = number(); cy = number()
            p.addLine(to: T(cx, cy))
            lastControlX = nil; lastControlY = nil
        case "l":
            cx += number(); cy += number()
            p.addLine(to: T(cx, cy))
            lastControlX = nil; lastControlY = nil
        case "H":
            cx = number()
            p.addLine(to: T(cx, cy))
            lastControlX = nil; lastControlY = nil
        case "h":
            cx += number()
            p.addLine(to: T(cx, cy))
            lastControlX = nil; lastControlY = nil
        case "V":
            cy = number()
            p.addLine(to: T(cx, cy))
            lastControlX = nil; lastControlY = nil
        case "v":
            cy += number()
            p.addLine(to: T(cx, cy))
            lastControlX = nil; lastControlY = nil
        case "C":
            let x1 = number(), y1 = number(), x2 = number(), y2 = number(), x = number(), y = number()
            p.addCurve(to: T(x, y), control1: T(x1, y1), control2: T(x2, y2))
            lastControlX = x2; lastControlY = y2
            cx = x; cy = y
        case "c":
            let x1 = number(), y1 = number(), x2 = number(), y2 = number(), x = number(), y = number()
            p.addCurve(to: T(cx + x, cy + y),
                       control1: T(cx + x1, cy + y1),
                       control2: T(cx + x2, cy + y2))
            lastControlX = cx + x2; lastControlY = cy + y2
            cx += x; cy += y
        case "S":
            // Smooth cubic: the first control point mirrors the previous one
            // through the current point. The outer arc is drawn with these, so
            // treating the mirror as the current point instead leaves a shape
            // that runs across the canvas rather than an arc.
            let x2 = number(), y2 = number(), x = number(), y = number()
            let m1 = T(2 * cx - (lastControlX ?? cx), 2 * cy - (lastControlY ?? cy))
            p.addCurve(to: T(x, y), control1: m1, control2: T(x2, y2))
            lastControlX = x2; lastControlY = y2
            cx = x; cy = y
        case "s":
            let x2 = number(), y2 = number(), x = number(), y = number()
            let m1 = T(2 * cx - (lastControlX ?? cx), 2 * cy - (lastControlY ?? cy))
            p.addCurve(to: T(cx + x, cy + y),
                       control1: m1,
                       control2: T(cx + x2, cy + y2))
            lastControlX = cx + x2; lastControlY = cy + y2
            cx += x; cy += y
        case "z", "Z":
            p.closeSubpath()
            cx = sx; cy = sy
            lastControlX = nil; lastControlY = nil
        default:
            continue
        }
    }
    return p
}

// Speaker body, then the two arcs. Same 24x24 grid, decreasing opacity outward.
let markPaths = [
    (path: "M3 9v6h4l5 5V4L7 9H3z", alpha: CGFloat(1.0)),
    // Each arc is authored as two halves meeting on the y = 12 axis. Keeping only
    // the upper half left the inner arc visibly lopsided, so the mirror is spelled
    // out rather than flipped at draw time.
    (path: "M16.5 12c0-1.77-1.02-3.29-2.5-4.03v2.21l2.45 2.45c.03-.2.05-.41.05-.63z", alpha: CGFloat(0.82)),
    (path: "M16.5 12c0 1.77-1.02 3.29-2.5 4.03v-2.21l2.45-2.45c.03 .2.05 .41.05 .63z", alpha: CGFloat(0.82)),
    (path: "M14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z", alpha: CGFloat(0.58)),
]
let markScale: CGFloat = 23.5

// The mark is drawn without a clip, so a path that escapes the body would simply
// paint over the canvas corners. A single mis-parsed control point once threw an
// arc to x = -16578, which no other step in the pipeline would have caught, so
// the geometry is checked here instead of only by eye.
let bodyBounds = bodyPath().boundingBox
let markBounds = markPaths.reduce(CGRect.null) { $0.union(markPath($1.path, scale: markScale).boundingBox) }
precondition(bodyBounds.insetBy(dx: -side * 0.06, dy: -side * 0.06).contains(markBounds),
             "mark escaped the body: \(markBounds) vs \(bodyBounds)")
precondition(abs(markBounds.midX - center) < 1.5 && abs(markBounds.midY - center) < 1.5,
             "mark is off-centre: \(markBounds)")

// MARK: - Draw
func render(size: Int, includeMark: Bool = true) -> CGImage {
    let dimension = CGFloat(size)
    guard let ctx = CGContext(data: nil,
                              width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
        FileHandle.standardError.write(Data("could not create context at \(size)\n".utf8))
        exit(1)
    }

    // Everything is drawn in 1024-unit space and scaled once at the end, so the
    // small sizes are a true reduction of the same artwork rather than a separate
    // drawing that drifts from it.
    ctx.scaleBy(x: dimension / canvas, y: dimension / canvas)

    let body = bodyPath()

    // A soft shadow so the icon sits above its background rather than on it.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 34,
                  color: rgb(0x00, 0x00, 0x00, 0.28))
    ctx.addPath(body)
    ctx.setFillColor(rgb(0, 0, 0, 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()

    // Diagonal sweep, lit from the top left.
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: inset, y: canvas - inset),
                           end: CGPoint(x: canvas - inset, y: inset),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // A wash of light in the upper left, which is what gives the surface a
    // material rather than the flatness of a single fill.
    if let sheen = CGGradient(colorsSpace: space,
                              colors: [rgb(0xFF, 0xFF, 0xFF, 0.26), rgb(0xFF, 0xFF, 0xFF, 0.0)] as CFArray,
                              locations: [0, 1]) {
        ctx.drawRadialGradient(sheen,
                               startCenter: CGPoint(x: inset + side * 0.26, y: canvas - inset - side * 0.24),
                               startRadius: 0,
                               endCenter: CGPoint(x: inset + side * 0.26, y: canvas - inset - side * 0.24),
                               endRadius: side * 0.92,
                               options: [])
    }
    ctx.restoreGState()

    // A hairline along the top edge: at small sizes this is most of what still
    // separates the icon from a flat square.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.setStrokeColor(rgb(0xFF, 0xFF, 0xFF, 0.16))
    ctx.setLineWidth(2.5)
    ctx.strokePath()
    ctx.restoreGState()

    // The mark, lifted slightly off the background by its own shadow.
    if includeMark {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 14,
                      color: rgb(0x1A, 0x0B, 0x3D, 0.30))
        for (path, alpha) in markPaths {
            ctx.addPath(markPath(path, scale: markScale))
            ctx.setFillColor(rgb(0xFF, 0xFF, 0xFF, alpha))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    guard let image = ctx.makeImage() else {
        FileHandle.standardError.write(Data("could not render \(size)\n".utf8))
        exit(1)
    }
    return image
}

// MARK: - Verify
// Checks the composited result rather than the path bounds. The outer arc is
// drawn at 0.42 opacity, so over the gradient it lands near 172/255: invisible
// to any brightness threshold and to bounds measured from geometry alone.
func pixels(_ image: CGImage) -> [UInt8] {
    let data = image.dataProvider!.data! as Data
    return [UInt8](data)
}

let plainImage = render(size: Int(canvas), includeMark: false)
let markedImage = render(size: Int(canvas))
let plain = pixels(plainImage), marked = pixels(markedImage)
precondition(plain.count == marked.count, "render size mismatch")

var changed = 0, minX = Int(canvas), maxX = 0, minY = Int(canvas), maxY = 0
var sumX = 0, sumY = 0
for y in 0..<Int(canvas) {
    for x in 0..<Int(canvas) {
        let i = (y * Int(canvas) + x) * 4
        let delta = abs(Int(marked[i]) - Int(plain[i]))
            + abs(Int(marked[i + 1]) - Int(plain[i + 1]))
            + abs(Int(marked[i + 2]) - Int(plain[i + 2]))
        if delta > 12 {
            changed += 1
            sumX += x; sumY += y
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
let inkBox = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
print("mark ink: \(changed)px (\(String(format: "%.1f", Double(changed) / (canvas * canvas) * 100))% of canvas)")
print("mark ink bbox in image rows: x \(minX)...\(maxX) y \(minY)...\(maxY)")
print("mark ink centroid: (\(sumX / changed), \(sumY / changed))")

// Rows grow downward, so the y centroid is compared against the mirrored centre.
precondition(changed > 0, "mark drew nothing")
// CGRect edges are CGFloat; compare in Int space to keep the bounds honest.
let inkMinX = Int(inkBox.minX), inkMaxX = Int(inkBox.maxX)
let inkMinY = Int(inkBox.minY), inkMaxY = Int(inkBox.maxY)
let bodyMin = Int(inset) - 2, bodyMax = Int(canvas - inset) + 2
precondition(inkMaxX <= bodyMax && inkMinX >= bodyMin,
             "mark escaped horizontally: \(inkMinX)...\(inkMaxX) vs body \(bodyMin)...\(bodyMax)")
precondition(inkMaxY <= bodyMax && inkMinY >= bodyMin,
             "mark escaped vertically: \(inkMinY)...\(inkMaxY) vs body \(bodyMin)...\(bodyMax)")
precondition(abs(Double(sumX) / Double(changed) - Double(center)) < 24,
             "mark ink is lopsided horizontally")
precondition(abs(Double(sumY) / Double(changed) - Double(canvas - center)) < 24,
             "mark ink is lopsided vertically")

// MARK: - Output
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Every size macOS asks for, and the backing scale for each.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

// Rendered per variant rather than cached: two variants legitimately share a
// pixel size, and drawing the artwork twice costs less than the bookkeeping.
for (name, pixels) in variants {
    let image = render(size: pixels)
    guard let destination = CGImageDestinationCreateWithURL(
              iconset.appendingPathComponent(name) as CFURL,
              UTType.png.identifier as CFString, 1, nil)
    else {
        FileHandle.standardError.write(Data("could not write \(name)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("could not finalise \(name)\n".utf8))
        exit(1)
    }
}

// iconutil is the only supported way to produce a valid multi-representation
// .icns, so it does the final packaging rather than this script.
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path,
                    "-o", outputDirectory.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

print("wrote Resources/AppIcon.icns from \(variants.count) representations")