import Darwin
import Foundation
import GuestpadNative

public enum ForwardingStatus: Equatable, Sendable {
    case starting, waitingForGuest, waitingForController, permissionNeeded, multipleGuests, forwarding
    case failed(String)
}

public struct ForwardingSnapshot: Equatable, Sendable {
    public var status: ForwardingStatus = .starting
    public var controller = ControllerState()
    public var reports: UInt64 = 0
    public var calibration: FaceCalibrationPrompt?
    public var faceMapping: FaceButtonMapping = .standard
    public var faceMappingSaved = false
    public init() {}
}

struct GuestSelector {
    struct Peer {
        var updated: TimeInterval
        var allowed: Bool
    }
    private(set) var peers: [UInt64: Peer] = [:]
    private(set) var controller: UInt32?
    private(set) var selectedPeer: UInt64?
    private var controllerSeenAt: TimeInterval?
    private let handoffQuietTime: TimeInterval = 0.25

    private mutating func clearController() {
        controller = nil
        controllerSeenAt = nil
    }

    mutating func refresh(with messages: [GPMessage], at time: TimeInterval) -> ForwardingStatus {
        peers = peers.filter { time - $0.value.updated < 3 }
        for message in messages where message.peer != 0 && (message.kind == 1 || message.kind == 2) {
            peers[message.peer] = Peer(updated: time, allowed: message.allowed != 0)
        }
        guard peers.count == 1, let (peer, observation) = peers.first else {
            selectedPeer = nil
            clearController()
            return peers.isEmpty ? .waitingForGuest : .multipleGuests
        }
        if selectedPeer != peer {
            clearController()
            selectedPeer = peer
        }
        guard observation.allowed else {
            clearController()
            return .permissionNeeded
        }
        let reports = messages.filter { $0.kind == 1 && $0.peer == peer && $0.allowed != 0 }
        if let controller, reports.contains(where: { $0.controller == controller }) {
            controllerSeenAt = time
        } else if let replacement = reports.first,
                  controllerSeenAt.map({ time - $0 >= handoffQuietTime }) ?? true {
            // Parsec can assign a fresh ID when the guest reconnects a pad.
            // Keep one source, and prefer the existing pad while it sends input.
            controller = replacement.controller
            controllerSeenAt = time
        }
        return controller == nil ? .waitingForController : .forwarding
    }

    func accepts(_ message: GPMessage) -> Bool {
        message.kind == 1 && message.allowed != 0 && message.peer == selectedPeer && message.controller == controller
    }
}

public final class ForwardingSession {
    private let queue = DispatchQueue(label: "app.guestpad.forwarding", qos: .userInteractive)
    private var socket: Int32 = -1
    private var listenerLock: Int32 = -1
    private var timer: DispatchSourceTimer?
    private var output: PadLinkOutput?
    private var selector = GuestSelector()
    private var snapshot = ForwardingSnapshot()
    private var lastHeartbeat: TimeInterval?
    private var bridgeStatus: UInt32 = 0
    private var lastInput: TimeInterval?
    private var lastRawButtons: UInt16 = 0
    private var calibration: FaceButtonCalibration?
    private var suppressFaceUntilRelease = false
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private let changed: (ForwardingSnapshot) -> Void

    public init(faceMapping: FaceButtonMapping = .standard,
                changed: @escaping (ForwardingSnapshot) -> Void) throws {
        self.changed = changed
        snapshot.faceMapping = faceMapping
        socket = gp_listen(&listenerLock)
        guard socket >= 0 else {
            if errno == EWOULDBLOCK {
                throw GuestpadError("Another Guestpad instance is already forwarding.")
            }
            throw GuestpadError("Could not open Guestpad’s private input connection.")
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        queue.sync { close() }
    }

    public func beginFaceCalibration() {
        queue.async { [weak self] in
            guard let self, self.snapshot.status == .forwarding, self.calibration == nil,
                  let output = self.output else { return }
            do {
                try output.submit(ControllerState())
                self.snapshot.controller = ControllerState()
                self.calibration = FaceButtonCalibration(heldButtons: self.lastRawButtons)
                self.snapshot.calibration = self.calibration?.prompt
                self.snapshot.faceMappingSaved = false
            } catch {
                self.fail(error)
            }
            self.changed(self.snapshot)
        }
    }

    public func cancelFaceCalibration() {
        queue.async { [weak self] in
            guard let self, self.calibration != nil else { return }
            self.calibration = nil
            self.snapshot.calibration = nil
            self.suppressFaceUntilRelease = self.lastRawButtons & FaceButtonMapping.mask != 0
            self.changed(self.snapshot)
        }
    }

    private func close() {
        timer?.cancel()
        timer = nil
        output = nil
        if socket >= 0 {
            gp_close(socket, listenerLock)
            socket = -1
            listenerLock = -1
        }
    }

    deinit { close() }

    private func poll() {
        let now = ProcessInfo.processInfo.systemUptime
        let previous = snapshot
        var messages: [GPMessage] = []
        for _ in 0..<256 {
            var message = GPMessage()
            let result = gp_read(socket, &message)
            if result <= 0 { break }
            if result != 1 { continue }
            if message.kind == 0 {
                lastHeartbeat = now
                bridgeStatus = message.status
            } else {
                messages.append(message)
            }
        }
        do {
            try forward(messages, at: now)
        } catch {
            fail(error)
        }
        if snapshot != previous { changed(snapshot) }
    }

    private func fail(_ error: Error) {
        snapshot.controller = ControllerState()
        snapshot.calibration = nil
        snapshot.status = .failed(error.localizedDescription)
        close()
    }

    private func forward(_ messages: [GPMessage], at now: TimeInterval) throws {
        if bridgeStatus > 1 {
            throw GuestpadError("The Parsec bridge rejected this core (status \(bridgeStatus)).")
        }
        if let lastHeartbeat, now - lastHeartbeat > 2 {
            throw GuestpadError("Parsec stopped responding. Start forwarding again.")
        }
        if bridgeStatus == 0 {
            if now - startedAt > 15 { throw GuestpadError("The Parsec bridge did not respond. Check that the running host was launched after preparation.") }
            return
        }
        let previousPeer = selector.selectedPeer
        let previousController = selector.controller
        snapshot.status = selector.refresh(with: messages, at: now)
        if snapshot.status == .permissionNeeded || snapshot.status == .multipleGuests {
            output = nil
        }
        if previousPeer != selector.selectedPeer || previousController != selector.controller {
            try output?.submit(ControllerState())
            calibration = nil
            snapshot.calibration = nil
            lastRawButtons = 0
            suppressFaceUntilRelease = false
            lastInput = nil
            snapshot.controller = ControllerState()
        }
        guard snapshot.status == .forwarding else { return }
        for message in messages where selector.accepts(message) {
            if output == nil { output = try PadLinkOutput() }
            var state = ControllerState(message)
            lastRawButtons = state.buttons
            lastInput = now
            if var capture = calibration {
                if let mapping = capture.capture(state.buttons) {
                    snapshot.faceMapping = mapping
                    snapshot.faceMappingSaved = true
                    snapshot.calibration = nil
                    calibration = nil
                } else {
                    snapshot.calibration = capture.prompt
                    calibration = capture
                }
                continue
            }
            if suppressFaceUntilRelease {
                if state.buttons & FaceButtonMapping.mask == 0 { suppressFaceUntilRelease = false }
                state.buttons &= ~FaceButtonMapping.mask
            }
            state = snapshot.faceMapping.apply(to: state)
            try output?.submit(state)
            if snapshot.controller != state { snapshot.reports += 1 }
            snapshot.controller = state
        }
        // A lost release must not leave a control held. Preserve an idle pad
        // until its guest disappears so games keep the same device.
        if let lastInput, now - lastInput > 1.5, snapshot.controller != ControllerState() {
            try output?.submit(ControllerState())
            snapshot.controller = ControllerState()
        }
    }
}
