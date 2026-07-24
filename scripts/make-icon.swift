import AppKit
import CoreGraphics
import UniformTypeIdentifiers

// Renders the Kuk app icon: a peeking eye whose iris is a tiny landscape
// photo. 1024x1024 master, macOS style: 824x824 rounded rect centered.

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255, a])!
}

// --- background squircle ----------------------------------------------------
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: 824, height: 824)
let bg = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

// soft drop shadow like system icons
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 36, color: color(0x000000, 0.35))
ctx.addPath(bg)
ctx.setFillColor(color(0x1B2B4B))
ctx.fillPath()
ctx.restoreGState()

// vertical gradient: deep indigo -> vivid blue
ctx.saveGState()
ctx.addPath(bg)
ctx.clip()
var grad = CGGradient(colorsSpace: cs, colors: [
    color(0x4A6CF7), color(0x232E6B)
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// subtle highlight in the top area
grad = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray,
                  locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])

// --- eye --------------------------------------------------------------------
let center = CGPoint(x: 512, y: 512)

// white almond sclera (two circular arcs)
let eyeW: CGFloat = 620, eyeH: CGFloat = 400
let eye = CGMutablePath()
eye.move(to: CGPoint(x: center.x - eyeW / 2, y: center.y))
eye.addQuadCurve(to: CGPoint(x: center.x + eyeW / 2, y: center.y),
                 control: CGPoint(x: center.x, y: center.y + eyeH))
eye.addQuadCurve(to: CGPoint(x: center.x - eyeW / 2, y: center.y),
                 control: CGPoint(x: center.x, y: center.y - eyeH))
eye.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: color(0x000000, 0.3))
ctx.addPath(eye)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

// --- iris = round landscape photo ------------------------------------------
let irisR: CGFloat = 175
let irisRect = CGRect(x: center.x - irisR, y: center.y - irisR, width: irisR * 2, height: irisR * 2)

ctx.saveGState()
ctx.addPath(eye)          // keep the iris inside the eye outline
ctx.clip()
ctx.addEllipse(in: irisRect)
ctx.clip()

// sunset sky
grad = CGGradient(colorsSpace: cs, colors: [color(0xFFD34D), color(0xFF7A3C)] as CFArray,
                  locations: [0, 1])!
ctx.drawLinearGradient(grad,
                       start: CGPoint(x: center.x, y: irisRect.maxY),
                       end: CGPoint(x: center.x, y: irisRect.minY), options: [])

// sun
ctx.setFillColor(color(0xFFF6D9))
ctx.fillEllipse(in: CGRect(x: center.x + 20, y: center.y + 40, width: 110, height: 110))

// back mountain
var m = CGMutablePath()
m.move(to: CGPoint(x: irisRect.minX - 20, y: irisRect.minY))
m.addLine(to: CGPoint(x: center.x - 60, y: center.y + 40))
m.addLine(to: CGPoint(x: center.x + 120, y: irisRect.minY))
m.closeSubpath()
ctx.addPath(m)
ctx.setFillColor(color(0x2E7D5B))
ctx.fillPath()

// front mountain
m = CGMutablePath()
m.move(to: CGPoint(x: center.x - 40, y: irisRect.minY))
m.addLine(to: CGPoint(x: center.x + 110, y: center.y - 10))
m.addLine(to: CGPoint(x: irisRect.maxX + 30, y: irisRect.minY))
m.closeSubpath()
ctx.addPath(m)
ctx.setFillColor(color(0x1F5C43))
ctx.fillPath()
ctx.restoreGState()

// iris ring
ctx.saveGState()
ctx.addPath(eye)
ctx.clip()
ctx.setStrokeColor(color(0x14213D))
ctx.setLineWidth(18)
ctx.strokeEllipse(in: irisRect.insetBy(dx: 9, dy: 9))

// glint
ctx.setFillColor(color(0xFFFFFF, 0.9))
ctx.fillEllipse(in: CGRect(x: center.x - 95, y: center.y + 62, width: 62, height: 62))
ctx.fillEllipse(in: CGRect(x: center.x - 30, y: center.y + 110, width: 26, height: 26))
ctx.restoreGState()

// --- write ------------------------------------------------------------------
let image = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("written \(out.path)")
