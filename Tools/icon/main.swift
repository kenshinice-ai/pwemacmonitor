import AppKit

// App icon, matching 01 BRAND ASSETS/logo/app-icon-512.svg: navy squircle, amber wing at 60 % width.
// Geometry comes from BrandMark, so the icon can never drift from the generated mark.
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
    let r = CGRect(x: 0, y: 0, width: size, height: size)
    let corner = size * 114.5 / 512      // same radius ratio as the brand app icon
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.setFillColor(CGColor(red: 14 / 255, green: 23 / 255, blue: 41 / 255, alpha: 1))
    ctx.fillPath()
    let w = size * 0.60
    let box = CGRect(x: (size - w) / 2, y: (size - w / BrandMark.aspect) / 2, width: w, height: w / BrandMark.aspect)
    BrandMark.draw(in: box, color: NSColor(srgbRed: 245 / 255, green: 179 / 255, blue: 53 / 255, alpha: 1))
    return true
}
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
