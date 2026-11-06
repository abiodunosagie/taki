import AppKit
// Taki icon: a dark squircle with three falling water streams that pool at the bottom.
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(path); ctx.clip()
let bg = CGGradient(colorsSpace: nil, colors: [CGColor(red: 0.10, green: 0.13, blue: 0.19, alpha: 1),
                                                CGColor(red: 0.03, green: 0.05, blue: 0.09, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
let water = CGGradient(colorsSpace: nil, colors: [CGColor(red: 0.62, green: 0.86, blue: 1.0, alpha: 1),
                                                   CGColor(red: 0.20, green: 0.52, blue: 1.0, alpha: 1)] as CFArray, locations: [0, 1])!
for (x, w, top) in [(360.0, 70.0, 780.0), (477.0, 70.0, 830.0), (594.0, 70.0, 760.0)] {
    ctx.saveGState()
    let s = CGPath(roundedRect: CGRect(x: x, y: 330, width: w, height: top - 330), cornerWidth: 35, cornerHeight: 35, transform: nil)
    ctx.addPath(s); ctx.clip()
    ctx.drawLinearGradient(water, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: 330), options: [])
    ctx.restoreGState()
}
ctx.saveGState()
let pool = CGPath(ellipseIn: CGRect(x: 280, y: 230, width: 464, height: 120), transform: nil)
ctx.addPath(pool); ctx.clip()
ctx.drawLinearGradient(water, start: CGPoint(x: 0, y: 350), end: CGPoint(x: 0, y: 230), options: [])
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
