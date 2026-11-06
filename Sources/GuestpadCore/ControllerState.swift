import Foundation
import GuestpadNative

public struct ControllerState: Equatable, Sendable {
    public var buttons: UInt16 = 0
    public var leftX: Int16 = 0
    public var leftY: Int16 = 0
    public var rightX: Int16 = 0
    public var rightY: Int16 = 0
    public var leftTrigger: UInt8 = 0
    public var rightTrigger: UInt8 = 0

    public init() {}

    init(_ message: GPMessage) {
        buttons = message.buttons
        (leftX, leftY, rightX, rightY) = message.axes
        (leftTrigger, rightTrigger) = message.triggers
    }

    // Parsec uses XInput button bits and upward-positive stick Y.
    var padLinkReport: [UInt8] {
        func axis(_ value: Int16, inverted: Bool = false) -> UInt8 {
            let position = inverted ? 32767 - Int(value) : Int(value) + 32768
            return UInt8(position >> 8)
        }
        let direction = buttons & 0xf
        let hats: [UInt16: UInt8] = [1: 0, 9: 1, 8: 2, 10: 3, 2: 4, 6: 5, 4: 6, 5: 7]
        var face = hats[direction] ?? 8
        if buttons & 0x4000 != 0 { face |= 0x10 } // X → Square
        if buttons & 0x1000 != 0 { face |= 0x20 } // A → Cross
        if buttons & 0x2000 != 0 { face |= 0x40 } // B → Circle
        if buttons & 0x8000 != 0 { face |= 0x80 } // Y → Triangle
        var middle: UInt8 = 0
        if buttons & 0x0100 != 0 { middle |= 0x01 }
        if buttons & 0x0200 != 0 { middle |= 0x02 }
        if leftTrigger > 0 { middle |= 0x04 }
        if rightTrigger > 0 { middle |= 0x08 }
        if buttons & 0x0020 != 0 { middle |= 0x10 }
        if buttons & 0x0010 != 0 { middle |= 0x20 }
        if buttons & 0x0040 != 0 { middle |= 0x40 }
        if buttons & 0x0080 != 0 { middle |= 0x80 }
        let guide: UInt8 = buttons & 0x0400 == 0 ? 0 : 1
        var report: [UInt8] = [
            0xf1, 1, axis(leftX), axis(leftY, inverted: true),
            axis(rightX), axis(rightY, inverted: true), face, middle, guide,
            leftTrigger, rightTrigger
        ]
        report += Array(repeating: 0, count: 65 - report.count)
        return report
    }
}
