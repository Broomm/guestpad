import Foundation

public struct FaceButtonMapping: Equatable, Sendable {
    // Standard Parsec face bits ordered by the destination positions.
    static let positions: [UInt16] = [0x1000, 0x2000, 0x8000, 0x4000]
    static let mask: UInt16 = 0xf000
    public static let standard = FaceButtonMapping(sources: positions)!

    public let sources: [UInt16]

    public init?(sources: [UInt16]) {
        guard sources.count == Self.positions.count, Set(sources) == Set(Self.positions) else { return nil }
        self.sources = sources
    }

    func apply(to state: ControllerState) -> ControllerState {
        var mapped = state
        mapped.buttons &= ~Self.mask
        for (source, destination) in zip(sources, Self.positions) where state.buttons & source != 0 {
            mapped.buttons |= destination
        }
        return mapped
    }
}

public struct FaceCalibrationPrompt: Equatable, Sendable {
    public let captured: Int
    public let needsRelease: Bool
    public let feedback: String?
}

struct FaceButtonCalibration {
    private var sources: [UInt16] = []
    private var needsRelease: Bool
    private var feedback: String?

    init(heldButtons: UInt16) {
        needsRelease = heldButtons & FaceButtonMapping.mask != 0
    }

    var prompt: FaceCalibrationPrompt {
        FaceCalibrationPrompt(captured: sources.count, needsRelease: needsRelease, feedback: feedback)
    }

    mutating func capture(_ buttons: UInt16) -> FaceButtonMapping? {
        let face = buttons & FaceButtonMapping.mask
        if face == 0 {
            needsRelease = false
            return FaceButtonMapping(sources: sources)
        }
        guard !needsRelease else { return nil }
        needsRelease = true
        guard face.nonzeroBitCount == 1 else {
            feedback = "Press one face button at a time."
            return nil
        }
        guard !sources.contains(face) else {
            feedback = "That button is already assigned. Press a different face button."
            return nil
        }
        sources.append(face)
        feedback = nil
        return nil
    }
}
