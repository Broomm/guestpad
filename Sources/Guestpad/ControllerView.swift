import SwiftUI
import GuestpadCore

struct ControllerView: View {
    let state: ControllerState

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                ControllerShell()
                    .fill(Color(white: 0.26).gradient)
                ControllerShell()
                    .stroke(.primary.opacity(0.18), lineWidth: 1)
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(white: 0.15))
                    .frame(width: 90, height: 39)
                    .position(point(0.50, 0.35, in: size))

                chip("L1", 0x100).position(point(0.23, 0.21, in: size))
                chip("R1", 0x200).position(point(0.77, 0.21, in: size))
                TriggerMeter(label: "L2", value: state.leftTrigger)
                    .position(point(0.23, 0.08, in: size))
                TriggerMeter(label: "R2", value: state.rightTrigger)
                    .position(point(0.77, 0.08, in: size))

                dpad.position(point(0.23, 0.46, in: size))
                stick(state.leftX, state.leftY, click: 0x40, label: "Left stick")
                    .position(point(0.37, 0.74, in: size))
                stick(state.rightX, state.rightY, click: 0x80, label: "Right stick")
                    .position(point(0.63, 0.74, in: size))
                faceButtons.position(point(0.77, 0.46, in: size))

                chip("Share", 0x20).position(point(0.39, 0.57, in: size))
                chip("PS", 0x400).position(point(0.50, 0.64, in: size))
                chip("Options", 0x10).position(point(0.61, 0.57, in: size))
            }
        }
        .frame(maxWidth: 365)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("DualShock 4 controller preview")
    }

    private func point(_ x: CGFloat, _ y: CGFloat, in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }

    private var dpad: some View {
        buttonDiamond(top: ("↑", 1), right: ("→", 8), bottom: ("↓", 2), left: ("←", 4))
    }

    private var faceButtons: some View {
        buttonDiamond(top: ("△", 0x8000), right: ("○", 0x2000), bottom: ("×", 0x1000), left: ("□", 0x4000))
    }

    private func buttonDiamond(
        top: (String, UInt16), right: (String, UInt16), bottom: (String, UInt16), left: (String, UInt16)
    ) -> some View {
        let spacing: CGFloat = 22
        let diameter: CGFloat = 23
        let side = spacing * 2 + diameter
        return ZStack {
            chip(top.0, top.1, diameter: diameter).offset(y: -spacing)
            chip(right.0, right.1, diameter: diameter).offset(x: spacing)
            chip(bottom.0, bottom.1, diameter: diameter).offset(y: spacing)
            chip(left.0, left.1, diameter: diameter).offset(x: -spacing)
        }
        .frame(width: side, height: side)
    }

    private func chip(_ label: String, _ mask: UInt16, diameter: CGFloat? = nil) -> some View {
        let pressed = state.buttons & mask != 0
        return Text(label)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, diameter == nil ? 6 : 0)
            .frame(width: diameter, height: diameter)
            .frame(minWidth: 23, minHeight: 21)
            .background(pressed ? Color.accentColor : Color(white: 0.12), in: Capsule())
            .accessibilityValue(pressed ? "Pressed" : "Released")
    }

    private func stick(_ x: Int16, _ y: Int16, click: UInt16, label: String) -> some View {
        ZStack {
            Circle().fill(Color(white: 0.12)).frame(width: 47, height: 47)
            Circle().fill(state.buttons & click != 0 ? Color.accentColor : Color(white: 0.54))
                .frame(width: 21, height: 21)
                .offset(x: CGFloat(x) / 32768 * 12, y: -CGFloat(y) / 32768 * 12)
        }
        .accessibilityLabel(label)
    }
}

private struct TriggerMeter: View {
    let label: String
    let value: UInt8

    var body: some View {
        let fraction = CGFloat(value) / 255
        HStack(spacing: 5) {
            Text(label).fontWeight(.semibold)
            ZStack(alignment: .leading) {
                Rectangle().fill(.secondary.opacity(0.22))
                Rectangle().fill(Color.accentColor).frame(width: 47 * fraction)
            }
            .frame(width: 47, height: 6)
            .clipShape(Capsule())
            Text("\(Int((fraction * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
        .font(.caption2)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

private struct ControllerShell: Shape {
    func path(in rect: CGRect) -> Path {
        let top: CGFloat = 0.20
        let grip: CGFloat = 0.87
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0.27, top))
        path.addQuadCurve(to: point(0.73, top), control: point(0.50, top - 0.05))
        path.addCurve(to: point(0.93, grip), control1: point(0.91, top), control2: point(0.98, 0.70))
        path.addQuadCurve(to: point(0.77, grip - 0.02), control: point(0.87, grip + 0.12))
        path.addQuadCurve(to: point(0.67, 0.79), control: point(0.72, 0.75))
        path.addQuadCurve(to: point(0.33, 0.79), control: point(0.50, 0.85))
        path.addQuadCurve(to: point(0.23, grip - 0.02), control: point(0.28, 0.75))
        path.addQuadCurve(to: point(0.07, grip), control: point(0.13, grip + 0.12))
        path.addCurve(to: point(0.27, top), control1: point(0.02, 0.70), control2: point(0.09, top))
        path.closeSubpath()
        return path
    }
}
