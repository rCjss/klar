import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// iPhone-Icon: schwarze Fläche, weißer Kreis (die Ecken rundet iOS selbst ab). Ohne Alphakanal.
//   swiftc make-icon.swift -o /tmp/make-icon && /tmp/make-icon Klar/Assets.xcassets/AppIcon.appiconset/AppIcon.png
let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
let r = Double(size) * 0.175
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.fillEllipse(in: CGRect(x: Double(size) / 2 - r, y: Double(size) / 2 - r, width: 2 * r, height: 2 * r))
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, context.makeImage()!, nil)
CGImageDestinationFinalize(dest)
