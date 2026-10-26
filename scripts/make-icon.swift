// Draws the GPS Spoofer icon: a location arrow mid-jump along a dotted arc between two pins.
// swift scripts/make-icon.swift <out.png> [size] [--rounded]   (rounded = macOS-style squircle with margin)
import AppKit

let args = CommandLine.arguments
let out = args[1]
let size = CGFloat(args.count > 2 ? Double(args[2]) ?? 1024 : 1024)
let rounded = args.contains("--rounded")

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let s = size / 1024

let accent = NSColor(srgbRed: 0.545, green: 0.427, blue: 1.0, alpha: 1)
let canvas = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.045, alpha: 1)

// background
let inset: CGFloat = rounded ? 100 * s : 0
let bgRect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bgPath = rounded ? NSBezierPath(roundedRect: bgRect, xRadius: 185 * s, yRadius: 185 * s) : NSBezierPath(rect: bgRect)
canvas.setFill(); bgPath.fill()
NSGraphicsContext.saveGraphicsState()
bgPath.addClip()
let glow = NSGradient(colors: [accent.withAlphaComponent(0.55), accent.withAlphaComponent(0.0)])!
glow.draw(fromCenter: CGPoint(x: 640 * s, y: 600 * s), radius: 0,
          toCenter: CGPoint(x: 640 * s, y: 600 * s), radius: 560 * s, options: [])

func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: bgRect.minX + x * bgRect.width / 1024, y: bgRect.minY + y * bgRect.height / 1024) }
let k = bgRect.width / 1024

// dotted jump arc from the small "real" pin (bottom-left) to the arrow (top-right)
let arc = NSBezierPath()
arc.move(to: p(270, 300))
arc.curve(to: p(640, 640), controlPoint1: p(250, 640), controlPoint2: p(420, 760))
arc.lineWidth = 26 * k
arc.lineCapStyle = .round
arc.setLineDash([0.1, 58 * k], count: 2, phase: 0)
NSColor.white.withAlphaComponent(0.55).setStroke(); arc.stroke()

// small hollow "real location" ring
let ring = NSBezierPath(ovalIn: CGRect(origin: p(222, 252), size: CGSize(width: 96 * k, height: 96 * k)))
ring.lineWidth = 22 * k
NSColor.white.withAlphaComponent(0.6).setStroke(); ring.stroke()

// the location arrow (navigation glyph), tilted toward the top-right
ctx.saveGState()
ctx.translateBy(x: p(660, 640).x, y: p(660, 640).y)
ctx.rotate(by: -.pi / 4)
let a = NSBezierPath()
let r = 230 * k
a.move(to: CGPoint(x: 0, y: r))
a.line(to: CGPoint(x: r * 0.72, y: -r * 0.78))
a.line(to: CGPoint(x: 0, y: -r * 0.38))
a.line(to: CGPoint(x: -r * 0.72, y: -r * 0.78))
a.close()
a.lineJoinStyle = .round
NSGraphicsContext.current!.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = accent.withAlphaComponent(0.9); shadow.shadowBlurRadius = 60 * k
shadow.set()
NSColor.white.setFill(); a.fill()
NSGraphicsContext.current!.restoreGraphicsState()
a.lineWidth = 18 * k
NSColor.white.setStroke(); a.stroke()
ctx.restoreGState()
NSGraphicsContext.restoreGraphicsState()

let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: out))
