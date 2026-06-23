// Generates the social link-preview image (Open Graph / Twitter), 1200×630.
//   swift scripts/make_og_image.swift img/og-image.png
// Run from the repo root so the relative img/ paths resolve.
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "img/og-image.png"
let W = 1200, H = 630

func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
}

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError() }
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

// Soft brand-lavender diagonal wash (matches the site's bgfx palette).
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(0xf7,0xf3,0xf8).cgColor, rgb(0xe4,0xd8,0xea).cgColor, rgb(0xf2,0xf0,0xf8).cgColor] as CFArray,
    locations: [0, 0.55, 1])!
cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(H)), end: CGPoint(x: CGFloat(W), y: 0),
                      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// Faint brand mark watermark, lower-right.
if let mark = NSImage(contentsOfFile: "img/mark_accent_v2.svg") {
    NSGraphicsContext.saveGraphicsState()
    let s: CGFloat = 460
    mark.draw(in: NSRect(x: CGFloat(W) - s + 110, y: -120, width: s, height: s),
              from: .zero, operation: .sourceOver, fraction: 0.10)
    NSGraphicsContext.restoreGraphicsState()
}

// App icon, left.
let iconSize: CGFloat = 300
let iconX: CGFloat = 96
if let icon = NSImage(contentsOfFile: "img/appicon_1024.png") {
    icon.draw(in: NSRect(x: iconX, y: (CGFloat(H) - iconSize)/2, width: iconSize, height: iconSize))
}

// Text block to the right of the icon. Helper measures from the TOP edge.
let tx = iconX + iconSize + 56
func text(_ s: String, _ font: NSFont, _ color: NSColor, top: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let ns = s as NSString
    let h = ns.size(withAttributes: attrs).height
    ns.draw(at: CGPoint(x: tx, y: CGFloat(H) - top - h), withAttributes: attrs)
}
text("clipandnote", .systemFont(ofSize: 82, weight: .heavy), rgb(0x24,0x1f,0x2b), top: 205)
text("Capture it, mark it up, move on.", .systemFont(ofSize: 34, weight: .semibold), rgb(0x52,0x4c,0x61), top: 312)
text("A native macOS screenshot-markup app.", .systemFont(ofSize: 26, weight: .regular), rgb(0x6b,0x61,0x75), top: 366)

ctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(W)×\(H))")
