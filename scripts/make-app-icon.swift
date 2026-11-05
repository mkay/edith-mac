// Renders the Linux app's SVG icon into App/Assets.xcassets/AppIcon.appiconset,
// placed on the macOS icon grid: a light 824 pt rounded square (continuous
// corners) centred on a 1024 pt canvas, as macOS expects, with the artwork on
// it. The Linux icon is a mark without a tile, and macOS would shrink such an
// icon into a grey one.
//
//     swift scripts/make-app-icon.swift path/to/de.singular.edith.svg

import AppKit

let args = CommandLine.arguments
guard args.count == 2, let svg = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write(Data("usage: make-app-icon.swift <icon.svg>  (or the SVG couldn't be read)\n".utf8))
    exit(1)
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = root.appending(path: "App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    // Apple's grid uses a 185.4 pt continuous-corner radius at 824 pt.
    let mask = NSBezierPath(roundedRect: body, xRadius: 185.4 * scale, yRadius: 185.4 * scale)
    mask.addClip()
    NSGradient(starting: NSColor(red: 0.96, green: 0.92, blue: 0.98, alpha: 1),
               ending: NSColor(red: 0.86, green: 0.77, blue: 0.93, alpha: 1))!.draw(in: body, angle: -90)
    // The mark nearly fills its own square, so this margin sets its size.
    svg.draw(in: body.insetBy(dx: 70 * scale, dy: 70 * scale), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: set.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: set.appending(path: "Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.write(to: set.deletingLastPathComponent().appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(images.count) icons to \(set.path)")
