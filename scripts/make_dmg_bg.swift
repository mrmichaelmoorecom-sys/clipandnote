// Generates the DMG background (soft lavender wash + faint clipandnote mark +
// arrow + headline). Uses system fonts only — no asset dependency.
//
//   swift scripts/make_dmg_bg.swift <outPath.png> <scale>
import AppKit
import CoreText

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "/tmp/dmgbg.png"
let scale = CGFloat(args.count > 2 ? (Double(args[2]) ?? 2) : 2)

let LW: CGFloat = 660, LH: CGFloat = 400
let W = Int(LW * scale), H = Int(LH * scale)

func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
}

// clipandnote's brand mark — extracted from Resources/menubar-icon.svg, plus a
// rounded "cn cut" square that's part of the wordmark logo.
let clipSVG = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="82 167 362 205" width="362" height="205" fill="#524c61">
  <defs>
    <mask id="cnCut" maskUnits="userSpaceOnUse" x="-2" y="0" width="510" height="512">
      <rect x="-2" y="0" width="510" height="512" fill="#fff"/>
      <rect x="288.857" y="211.844" width="174.536" height="172.969" rx="52.4" fill="#000"/>
    </mask>
  </defs>
  <g mask="url(#cnCut)">
    <g transform="rotate(90 223 250)">
      <path d="M293.1,180.2v133.8c0,25.7-20.8,46.5-46.5,46.5s-46.5-20.8-46.5-46.5v-145.5c0-16.1,13-29.1,29.1-29.1s29.1,13,29.1,29.1v122.2c0,6.4-5.2,11.6-11.6,11.6s-11.6-5.2-11.6-11.6v-110.5h-17.5v110.5c0,16.1,13,29.1,29.1,29.1s29.1-13,29.1-29.1v-122.2c0-25.7-20.8-46.5-46.5-46.5s-46.5,20.8-46.5,46.5v145.5c0,35.4,28.6,64,64,64s64-28.6,64-64v-133.8h-17.5Z"/>
    </g>
  </g>
</svg>
"""
let clipURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cnclip.svg")
try? clipSVG.write(to: clipURL, atomically: true, encoding: .utf8)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError() }

NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let cg = gctx.cgContext
cg.scaleBy(x: scale, y: scale)

// Soft lavender diagonal wash — picks up clipandnote's #524c61 brand colour at
// very low saturation so it stays as a backdrop, not a foreground.
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(0xf6,0xf5,0xfa).cgColor,
             rgb(0xeb,0xe8,0xf3).cgColor,
             rgb(0xf2,0xf0,0xf8).cgColor] as CFArray,
    locations: [0, 0.55, 1])!
cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: LH), end: CGPoint(x: LW, y: 0),
                      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// Faint clipandnote mark, large, tilted, lower-right corner.
if let mark = NSImage(contentsOf: clipURL) {
    NSGraphicsContext.saveGraphicsState()
    cg.translateBy(x: 510, y: 150)
    cg.rotate(by: -16 * .pi / 180)
    let s: CGFloat = 300
    mark.draw(in: CGRect(x: -s/2, y: -s/2, width: s, height: s),
              from: .zero, operation: .sourceOver, fraction: 0.10)
    NSGraphicsContext.restoreGraphicsState()
}

// Arrow between the .app icon and the Applications icon (icon row at y=200).
let arrow = NSBezierPath()
arrow.lineWidth = 11; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
arrow.move(to: CGPoint(x: 283, y: 200)); arrow.line(to: CGPoint(x: 377, y: 200))
arrow.move(to: CGPoint(x: 377, y: 200)); arrow.line(to: CGPoint(x: 350, y: 173))
arrow.move(to: CGPoint(x: 377, y: 200)); arrow.line(to: CGPoint(x: 350, y: 227))
rgb(0x2e, 0x2a, 0x33).setStroke()
arrow.stroke()

// Headline — system font, soft glow against the wash.
let text = "Snap. Mark. Share."
let font = NSFont.systemFont(ofSize: 36, weight: .heavy)
let para = NSMutableParagraphStyle(); para.alignment = .center
let glow = NSShadow(); glow.shadowColor = NSColor.white.withAlphaComponent(0.7)
glow.shadowBlurRadius = 5; glow.shadowOffset = .zero
let astr = NSAttributedString(string: text, attributes: [
    .font: font,
    .foregroundColor: rgb(0x2e, 0x2a, 0x33),
    .paragraphStyle: para,
    .shadow: glow])
let ts = astr.size()
astr.draw(at: CGPoint(x: (LW - ts.width)/2, y: LH - 36 - ts.height))

gctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
