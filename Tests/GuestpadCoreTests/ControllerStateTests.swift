import GuestpadNative
import XCTest
@testable import GuestpadCore

final class ControllerStateTests: XCTestCase {
    func testCrossAndStickReachExpectedPadLinkControls() {
        var state = ControllerState()
        state.buttons = 0x1000 | 0x0009
        state.leftX = 24576
        state.rightY = 32767
        state.rightTrigger = 200
        XCTAssertEqual(Array(state.padLinkReport.prefix(11)), [0xf1, 1, 224, 127, 128, 0, 0x21, 0x08, 0, 0, 200])
    }

    func testSecondGuestSuspendsRoutingAndPermissionRevocationClearsSelection() {
        var selection = GuestSelector()
        var first = GPMessage()
        first.kind = 1
        first.peer = 7
        first.controller = 1
        first.allowed = 1
        XCTAssertEqual(selection.refresh(with: [first], at: 0), .forwarding)
        XCTAssertTrue(selection.accepts(first))
        var second = first
        second.peer = 8
        XCTAssertEqual(selection.refresh(with: [first, second], at: 1), .multipleGuests)
        XCTAssertFalse(selection.accepts(first))
        XCTAssertEqual(selection.refresh(with: [first], at: 5), .forwarding)
        first.allowed = 0
        XCTAssertEqual(selection.refresh(with: [first], at: 6), .permissionNeeded)
        XCTAssertFalse(selection.accepts(first))
        XCTAssertEqual(selection.refresh(with: [], at: 10), .waitingForGuest)
    }

    func testCalibrationCapturesNintendoPositionsAndPreservesOtherControls() {
        var calibration = FaceButtonCalibration(heldButtons: 0x1000)
        XCTAssertEqual(calibration.capture(0x1000), nil)
        XCTAssertEqual(calibration.prompt.captured, 0)
        XCTAssertEqual(calibration.capture(0), nil)
        XCTAssertEqual(calibration.capture(0x1000), nil)
        XCTAssertEqual(calibration.capture(0x1000), nil)
        XCTAssertEqual(calibration.prompt.captured, 1)
        XCTAssertEqual(calibration.capture(0), nil)
        XCTAssertEqual(calibration.capture(0x1000), nil)
        XCTAssertEqual(calibration.prompt.captured, 1)
        XCTAssertEqual(calibration.capture(0), nil)
        XCTAssertEqual(calibration.capture(0xc000), nil)
        XCTAssertEqual(calibration.prompt.captured, 1)
        XCTAssertEqual(calibration.capture(0), nil)
        for button: UInt16 in [0x2000, 0x4000] {
            XCTAssertEqual(calibration.capture(button), nil)
            XCTAssertEqual(calibration.capture(0), nil)
        }
        XCTAssertEqual(calibration.capture(0x8000), nil)
        XCTAssertEqual(calibration.prompt.captured, 4)
        let mapping = calibration.capture(0)
        XCTAssertEqual(mapping?.sources, [0x1000, 0x2000, 0x4000, 0x8000])
        var raw = ControllerState()
        raw.buttons = 0x8100
        raw.leftX = 12345
        XCTAssertEqual(mapping?.apply(to: raw).buttons, 0x4100)
        XCTAssertEqual(mapping?.apply(to: raw).leftX, 12345)
        raw.buttons = 0x4000
        XCTAssertEqual(mapping?.apply(to: raw).padLinkReport[6], 0x88)
    }

    func testReconnectedControllerCanReplaceAnIdleIDWithoutReselectingGuest() {
        var selection = GuestSelector()
        var original = GPMessage()
        original.kind = 1
        original.peer = 7
        original.controller = 18
        original.allowed = 1
        var reconnected = original
        reconnected.controller = 19
        var keepalive = original
        keepalive.kind = 2

        XCTAssertEqual(selection.refresh(with: [original], at: 0), .forwarding)
        XCTAssertEqual(selection.refresh(with: [reconnected], at: 0.1), .forwarding)
        XCTAssertTrue(selection.accepts(original))
        XCTAssertFalse(selection.accepts(reconnected))
        XCTAssertEqual(selection.refresh(with: [keepalive], at: 1), .forwarding)
        XCTAssertEqual(selection.controller, 18)
        XCTAssertEqual(selection.refresh(with: [reconnected], at: 1.1), .forwarding)
        XCTAssertEqual(selection.selectedPeer, 7)
        XCTAssertTrue(selection.accepts(reconnected))
        XCTAssertFalse(selection.accepts(original))
    }

    func testCurrentControllerTakesPrecedenceInAnOverlappingBatch() {
        var selection = GuestSelector()
        var original = GPMessage()
        original.kind = 1
        original.peer = 7
        original.controller = 18
        original.allowed = 1
        var other = original
        other.controller = 19

        XCTAssertEqual(selection.refresh(with: [original], at: 0), .forwarding)
        XCTAssertEqual(selection.refresh(with: [other, original], at: 1), .forwarding)
        XCTAssertTrue(selection.accepts(original))
        XCTAssertFalse(selection.accepts(other))
    }
}
