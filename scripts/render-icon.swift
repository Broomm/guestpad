import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct RenderIcon {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for size in [16, 32, 128, 256, 512] {
            for scale in 1...2 {
                let pixels = size * scale
                let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                        bytesPerRow: pixels * 4, space: space,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.translateBy(x: 0, y: CGFloat(pixels))
                context.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)
                let tile = CGPath(roundedRect: CGRect(x: 96, y: 96, width: 832, height: 832),
                                  cornerWidth: 184, cornerHeight: 184, transform: nil)
                context.saveGState()
                context.addPath(tile)
                context.clip()
                let charcoal = [
                    CGColor(red: 0.23, green: 0.23, blue: 0.25, alpha: 1),
                    CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
                ]
                let gradient = CGGradient(colorsSpace: space, colors: charcoal as CFArray, locations: [0, 1])!
                context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 96),
                                           end: CGPoint(x: 512, y: 928), options: [])
                context.restoreGState()

                let glyph = GuestpadGlyph().path(in: CGRect(x: 179, y: 279, width: 666, height: 466))
                context.addPath(glyph.cgPath)
                context.setFillColor(CGColor(red: 1, green: 0.27, blue: 0.32, alpha: 1))
                context.fillPath(using: .evenOdd)

                let suffix = scale == 2 ? "@2x" : ""
                let file = output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
                let encoder = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(encoder, context.makeImage()!, nil)
                guard CGImageDestinationFinalize(encoder) else { throw CocoaError(.fileWriteUnknown) }
            }
        }
    }
}
