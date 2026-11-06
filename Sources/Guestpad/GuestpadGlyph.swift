import SwiftUI

struct GuestpadGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 100, rect.height / 70)
        let origin = CGPoint(x: rect.midX - 50 * scale, y: rect.midY - 35 * scale)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(origin: point(x, y), size: CGSize(width: width * scale, height: height * scale))
        }

        var mark = Path()
        mark.move(to: point(23, 9))
        mark.addLine(to: point(77, 9))
        mark.addQuadCurve(to: point(90, 22), control: point(86, 9))
        mark.addCurve(to: point(97, 51), control1: point(94, 32), control2: point(98, 42))
        mark.addQuadCurve(to: point(84, 62), control: point(96, 62))
        mark.addQuadCurve(to: point(75, 57), control: point(80, 62))
        mark.addLine(to: point(65, 49))
        mark.addLine(to: point(35, 49))
        mark.addLine(to: point(25, 57))
        mark.addQuadCurve(to: point(16, 62), control: point(20, 62))
        mark.addQuadCurve(to: point(3, 51), control: point(4, 62))
        mark.addCurve(to: point(10, 22), control1: point(2, 42), control2: point(6, 32))
        mark.addQuadCurve(to: point(23, 9), control: point(14, 9))
        mark.closeSubpath()

        // The same cutouts are used in the window and in the packaged icon.
        for (x, y) in [(26.0, 20.0), (31.0, 20.0), (31.0, 25.0), (36.0, 25.0),
                       (36.0, 30.0), (31.0, 30.0), (31.0, 35.0), (26.0, 35.0),
                       (26.0, 30.0), (21.0, 30.0), (21.0, 25.0), (26.0, 25.0)] {
            if x == 26, y == 20 { mark.move(to: point(x, y)) }
            else { mark.addLine(to: point(x, y)) }
        }
        mark.closeSubpath()
        mark.addRoundedRect(in: box(42, 17, 16, 7), cornerSize: CGSize(width: 2 * scale, height: 2 * scale))
        for (x, y) in [(71.0, 21.0), (77.0, 27.0), (71.0, 33.0), (65.0, 27.0)] {
            mark.addEllipse(in: box(x - 2.7, y - 2.7, 5.4, 5.4))
        }
        mark.addEllipse(in: box(39, 34, 8, 8))
        mark.addEllipse(in: box(53, 34, 8, 8))
        return mark
    }
}
