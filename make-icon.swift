import AppKit

// Minimalistisches Icon: schwarzes abgerundetes Quadrat, weißer Kreis.
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()
let inset = size * 0.1
let square = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset), xRadius: size * 0.19, yRadius: size * 0.19)
NSColor.black.setFill()
square.fill()
let r = size * 0.14
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: size / 2 - r, y: size / 2 - r, width: 2 * r, height: 2 * r)).fill()
image.unlockFocus()

let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
