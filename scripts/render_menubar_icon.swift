import AppKit
// Render Resources/menubar-icon.svg → crisp template PNG (hard 1-bit alpha).
//   swift scripts/render_menubar_icon.swift <png-out> <width> <height>
// Used to produce Resources/menubarTemplate.png (28×16) and @2x.png (56×32).
let svg = URL(fileURLWithPath: "Resources/menubar-icon.svg")
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let w = Int(CommandLine.arguments[2])!
let h = Int(CommandLine.arguments[3])!
guard let img = NSImage(contentsOf: svg) else { fputs("can't read svg\n", stderr); exit(1) }

let over = 8
let bigW = w * over, bigH = h * over
img.size = NSSize(width: bigW, height: bigH)
guard let big = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bigW, pixelsHigh: bigH,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: bigW * 4, bitsPerPixel: 32) else { exit(1) }
big.size = NSSize(width: bigW, height: bigH)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: big)
NSGraphicsContext.current?.imageInterpolation = .high
img.draw(in: NSRect(x: 0, y: 0, width: bigW, height: bigH))
NSGraphicsContext.restoreGraphicsState()

guard let final = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32) else { exit(1) }
guard let bigBuf = big.bitmapData, let outBuf = final.bitmapData else { exit(1) }
let bigStride = big.bytesPerRow, outStride = final.bytesPerRow
let block = over * over

for y in 0..<h {
    for x in 0..<w {
        var aSum = 0
        for dy in 0..<over {
            let ry = y * over + dy
            for dx in 0..<over { aSum += Int(bigBuf[ry * bigStride + (x*over+dx) * 4 + 3]) }
        }
        let i = y * outStride + x * 4
        outBuf[i] = 0; outBuf[i+1] = 0; outBuf[i+2] = 0
        outBuf[i+3] = (aSum / block) >= 128 ? 255 : 0
    }
}
try! final.representation(using: .png, properties: [:])!.write(to: out)
