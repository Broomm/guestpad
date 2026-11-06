import SwiftUI
import GuestpadCore

@MainActor
final class GuestpadModel: ObservableObject {
    @Published var parsec: Parsec?
    @Published var parsecNote = "Checking…"
    @Published var padLinkReady = false
    @Published var padLinkNote = "Checking…"
    @Published var snapshot = ForwardingSnapshot()
    @Published var running = false
    @Published var busy = false
    @Published var error: String?
    @Published var confirmPrepare = false
    private var session: ForwardingSession?
    private static let faceMappingKey = "FaceButtonMapping"
    private var faceMapping: FaceButtonMapping = {
        let stored = UserDefaults.standard.array(forKey: GuestpadModel.faceMappingKey) as? [Int] ?? []
        return FaceButtonMapping(sources: stored.compactMap(UInt16.init(exactly:))) ?? .standard
    }()
    private var generation = UUID()
    private var quitObserver: NSObjectProtocol?

    init() {
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func refresh() async {
        let results = await Task.detached {
            (Result { try Parsec.inspect() }, Result { try PadLink.check() })
        }.value
        switch results.0 {
        case .success(let host):
            parsec = host
            parsecNote = host.prepared ? "Ready" : "Preparation required"
        case .failure(let error):
            parsec = nil
            parsecNote = error.localizedDescription
        }
        switch results.1 {
        case .success:
            padLinkReady = true
            padLinkNote = "Driver ready"
        case .failure(let error):
            padLinkReady = false
            padLinkNote = error.localizedDescription
        }
    }

    func prepare() async {
        guard !busy, let parsec else { return }
        busy = true
        error = nil
        defer { busy = false }
        guard let bridge = Bundle.main.url(forResource: "libGuestpadReceive", withExtension: "dylib") else {
            error = "The Parsec bridge is missing. Open the packaged Guestpad app."
            return
        }
        do {
            try await parsec.quitRunning()
            try await Task.detached { try parsec.prepare(bridge: bridge) }.value
        } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func start() async {
        guard !busy, !running else { return }
        busy = true
        error = nil
        defer { busy = false }
        await refresh()
        guard let parsec, parsec.prepared, padLinkReady else { return }
        do {
            let id = UUID()
            generation = id
            snapshot = ForwardingSnapshot()
            let session = try ForwardingSession(faceMapping: faceMapping) { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.generation == id else { return }
                    if case .failed(let error) = state.status {
                        self.error = error
                        self.stop()
                    } else {
                        if self.faceMapping != state.faceMapping {
                            self.faceMapping = state.faceMapping
                            UserDefaults.standard.set(state.faceMapping.sources.map(Int.init), forKey: Self.faceMappingKey)
                        }
                        self.snapshot = state
                    }
                }
            }
            self.session = session
            running = true
            try await parsec.launchIfNeeded()
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    func calibrateFaceButtons() { session?.beginFaceCalibration() }
    func cancelFaceCalibration() { session?.cancelFaceCalibration() }

    func stop() {
        generation = UUID()
        session?.stop()
        session = nil
        running = false
        snapshot = ForwardingSnapshot()
    }

    var status: String {
        guard running else { return "Forwarding off" }
        switch snapshot.status {
        case .starting: return "Connecting to Parsec…"
        case .waitingForGuest: return "Waiting for a Parsec guest"
        case .waitingForController: return "Guest connected. Move a stick or press a button."
        case .permissionNeeded: return "Enable Gamepad permission for the guest in Parsec"
        case .multipleGuests: return "Multiple guests detected. Forwarding paused."
        case .forwarding: return "Forwarding to DualShock 4"
        case .failed(let error): return error
        }
    }
}

@main
struct GuestpadApp: App {
    @StateObject private var model = GuestpadModel()
    @StateObject private var updater = GuestpadUpdateModel()

    var body: some Scene {
        Window("Guestpad", id: "main") {
            GuestpadView(model: model, updater: updater)
                .frame(minWidth: 580, minHeight: 660)
                .task { await model.refresh() }
                .task { await updater.monitor() }
        }
        .defaultSize(width: 640, height: 680)
        .windowResizability(.contentMinSize)
    }
}

struct GuestpadView: View {
    @ObservedObject var model: GuestpadModel
    @ObservedObject var updater: GuestpadUpdateModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    GuestpadGlyph()
                        .fill(.tint, style: FillStyle(eoFill: true))
                        .frame(width: 42, height: 30)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Guestpad").font(.largeTitle.bold())
                        Text("Parsec controller forwarding").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if updater.installing {
                        ProgressView().controlSize(.small).accessibilityLabel("Installing update")
                    } else if let release = updater.available {
                        Button("Update to \(release.version)") { Task { await updater.install() } }
                            .help("Install the update and relaunch Guestpad")
                            .disabled(model.busy)
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 9) {
                        requirement("Parsec", note: model.parsecNote, ready: model.parsec?.prepared == true)
                        Divider()
                        requirement("PadLink", note: model.padLinkNote, ready: model.padLinkReady)
                        if !model.padLinkReady {
                            Link("Get PadLink", destination: URL(string: "https://padlink.nimets.com/")!)
                        }
                    }.padding(6)
                }
                GroupBox {
                    VStack(spacing: 10) {
                        ControllerView(state: model.snapshot.controller)
                            .frame(height: 220)
                            .opacity(model.snapshot.status == .forwarding ? 1 : 0.55)
                        Text(model.status).font(.headline)
                        Text("Mac output: DualShock 4 via PadLink").font(.caption).foregroundStyle(.secondary)
                        if let prompt = model.snapshot.calibration {
                            calibrationPanel(prompt)
                        } else {
                            Button("Calibrate Face Buttons…") { model.calibrateFaceButtons() }
                                .disabled(model.snapshot.status != .forwarding)
                            if model.snapshot.faceMappingSaved {
                                Text("Face button mapping saved.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity).padding(10)
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Refresh") { Task { await model.refresh() } }
                        .disabled(model.busy || model.running || updater.installing)
                    Spacer()
                    if model.parsec?.prepared == false {
                        Button("Prepare Parsec…") { model.confirmPrepare = true }
                            .buttonStyle(.borderedProminent).disabled(model.busy || updater.installing)
                    } else if model.running {
                        Button("Stop Forwarding") { model.stop() }.disabled(model.busy)
                    } else {
                        Button("Start Forwarding") { Task { await model.start() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy || updater.installing || model.parsec == nil || !model.padLinkReady)
                    }
                }
                Text("After preparation, open Parsec normally. Start or stop forwarding anytime.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .alert("Couldn’t update Guestpad", isPresented: Binding(
            get: { updater.installError != nil },
            set: { if !$0 { updater.installError = nil } }
        )) {
            Button("Open GitHub Releases") { NSWorkspace.shared.open(GuestpadUpdates.releasesPage) }
            Button("OK", role: .cancel) {}
        } message: {
            Text(updater.installError ?? "")
        }
        .confirmationDialog("Prepare the installed Parsec app?", isPresented: $model.confirmPrepare, titleVisibility: .visible) {
            Button("Prepare Parsec") { Task { await model.prepare() } }
        } message: {
            Text("Preparation quits Parsec and disconnects any guest once. Guestpad saves the original app, adds the bridge, re-signs Parsec, and resets its Screen Recording, Accessibility, and Microphone permissions. macOS may ask you to grant them again.")
        }
    }

    private func calibrationPanel(_ prompt: FaceCalibrationPrompt) -> some View {
        let positions = ["bottom (×)", "right (○)", "top (△)", "left (□)"]
        let next = positions[min(prompt.captured, positions.count - 1)]
        return VStack(spacing: 8) {
            Text("Face button calibration").font(.headline)
            ProgressView(value: Double(prompt.captured), total: Double(positions.count))
                .frame(maxWidth: 220)
                .accessibilityLabel("\(prompt.captured) of four buttons captured")
            if prompt.captured == positions.count {
                Text("Release the last button to save the mapping.")
            } else if prompt.needsRelease {
                Text("Release the face buttons, then press \(next).")
            } else {
                Text("Press the \(next) face button.")
            }
            if let feedback = prompt.feedback {
                Text(feedback).foregroundStyle(.orange)
            }
            Text("Game input is paused while you calibrate.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Cancel Calibration") { model.cancelFaceCalibration() }
        }.padding(.top, 4)
    }

    private func requirement(_ title: String, note: String, ready: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(ready ? Color.green : Color.secondary)
            Text(title).fontWeight(.semibold).frame(width: 58, alignment: .leading)
            Text(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
