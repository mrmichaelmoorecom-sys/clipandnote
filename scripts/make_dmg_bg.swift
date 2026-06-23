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

// clipandnote's "mark accent" variant — the clip-mark + notepad composite
// from img/mark_accent_v2.svg. The two-tone purple palette (#a29ab1 + #524c61)
// matches the app icon. The external <image> reference is stripped since it
// won't resolve when NSImage loads this string.
let clipSVG = """
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 512 512">
  <defs>
    <style>
      .st0 { fill: #a29ab1; }
      .st1 { fill: #524c61; }
    </style>
  </defs>
  <path class="st0" d="M203.5,129v133.8c0,25.7-20.8,46.5-46.5,46.5s-46.5-20.8-46.5-46.5V117.3c0-16.1,13-29.1,29.1-29.1s29.1,13,29.1,29.1v122.2c0,6.4-5.2,11.6-11.6,11.6s-11.6-5.2-11.6-11.6v-110.5h-17.5v110.5c0,16.1,13,29.1,29.1,29.1s29.1-13,29.1-29.1v-122.2c0-25.7-20.8-46.5-46.5-46.5s-46.5,20.8-46.5,46.5v145.5c0,35.4,28.6,64,64,64s64-28.6,64-64v-133.8h-17.5Z"/>
  <g>
    <path class="st1" d="M246.6,360.5c-25.7,0-46.5-20.8-46.5-46.5v-145.5c0-16.1,13-29.1,29.1-29.1s29.1,13,29.1,29.1v122.2c0,6.4-5.2,11.6-11.6,11.6s-11.6-5.2-11.6-11.6v-110.5h-17.5v110.5c0,16.1,13,29.1,29.1,29.1s3.6-.2,5.4-.5c2.1-13.1,11.4-23.8,23.7-27.9,0-.2,0-.4,0-.6v-122.2c0-25.7-20.8-46.5-46.5-46.5s-46.5,20.8-46.5,46.5v145.5c0,35.4,28.6,64,64,64s3.3,0,4.9-.2v-17.5c-1.6.2-3.3.3-4.9.3Z"/>
    <rect class="st1" x="293.1" y="180.2" width="17.5" height="109.3"/>
  </g>
  <circle class="st1" cx="311" cy="347" r="13"/>
  <rect class="st1" x="334" y="340" width="48" height="16"/>
  <circle class="st1" cx="311" cy="380" r="13"/>
  <rect class="st1" x="334" y="373" width="48" height="16"/>
  <circle class="st1" cx="311" cy="413" r="13"/>
  <rect class="st1" x="334" y="406" width="48" height="16"/>
  <path class="st1" d="M395.7,455.3h-105.8c-12.8,0-23.1-10.4-23.1-23.1v-103.4c0-12.8,10.4-23.1,23.1-23.1h105.8c12.8,0,23.1,10.4,23.1,23.1v103.4c0,12.8-10.4,23.1-23.1,23.1ZM289.9,320.6c-4.5,0-8.1,3.6-8.1,8.1v103.4c0,4.5,3.6,8.1,8.1,8.1h105.8c4.5,0,8.1-3.6,8.1-8.1v-103.4c0-4.5-3.6-8.1-8.1-8.1h-105.8Z"/>
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

// Lavender diagonal wash — picks up clipandnote's brand purples at low
// saturation. The mid-tone is noticeably deeper than the endpoints so the
// gradient reads as a real wash rather than near-flat off-white.
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(0xf6,0xf5,0xfa).cgColor,
             rgb(0xd6,0xcf,0xe5).cgColor,
             rgb(0xee,0xeb,0xf6).cgColor] as CFArray,
    locations: [0, 0.55, 1])!
cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: LH), end: CGPoint(x: LW, y: 0),
                      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// Mark-accent watermark — large, tilted, lower-right corner. The two-tone
// purple shows through the wash for a brand-colored backdrop element instead
// of a generic grey watermark.
if let mark = NSImage(contentsOf: clipURL) {
    NSGraphicsContext.saveGraphicsState()
    cg.translateBy(x: 510, y: 150)
    cg.rotate(by: -16 * .pi / 180)
    let s: CGFloat = 300
    mark.draw(in: CGRect(x: -s/2, y: -s/2, width: s, height: s),
              from: .zero, operation: .sourceOver, fraction: 0.22)
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

// Headline + subtitle — system font, soft glow against the wash. The
// subtitle is a smaller medium-weight tagline that sits right under the
// headline.
let para = NSMutableParagraphStyle(); para.alignment = .center
let glow = NSShadow(); glow.shadowColor = NSColor.white.withAlphaComponent(0.7)
glow.shadowBlurRadius = 5; glow.shadowOffset = .zero

let head = NSAttributedString(string: "Clip. Note. Share.", attributes: [
    .font: NSFont.systemFont(ofSize: 36, weight: .heavy),
    .foregroundColor: rgb(0x2e, 0x2a, 0x33),
    .paragraphStyle: para,
    .shadow: glow])
let sub = NSAttributedString(string: "clip it. clip it good.", attributes: [
    .font: NSFont.systemFont(ofSize: 16, weight: .medium),
    .foregroundColor: rgb(0x2e, 0x2a, 0x33),
    .paragraphStyle: para,
    .shadow: glow])
let hs = head.size()
let ss = sub.size()
let topMargin: CGFloat = 30
head.draw(at: CGPoint(x: (LW - hs.width)/2, y: LH - topMargin - hs.height))
sub.draw(at: CGPoint(x: (LW - ss.width)/2, y: LH - topMargin - hs.height - ss.height - 4))

gctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
