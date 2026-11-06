import AppKit
import GuestpadCore
import SwiftUI

@MainActor
final class GuestpadUpdateModel: ObservableObject {
    @Published private(set) var available: GuestpadRelease?
    @Published private(set) var installing = false
    @Published var installError: String?

    private let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    func monitor() async {
        guard let installedVersion else { return }
        while !Task.isCancelled {
            do {
                let release = try await GuestpadUpdates.latest(after: installedVersion)
                if !installing { available = release }
            } catch {
                // A network failure should leave forwarding and a known update available.
            }
            do { try await Task.sleep(for: .seconds(6 * 60 * 60)) }
            catch { return }
        }
    }

    func install() async {
        guard let release = available, let installedVersion, !installing else { return }
        installing = true
        installError = nil
        defer { installing = false }
        do {
            let replacement = try await GuestpadUpdates.install(release, replacing: Bundle.main.bundleURL,
                                                               installedVersion: installedVersion)
            do {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                let relaunched = try await NSWorkspace.shared.openApplication(at: replacement.installed, configuration: configuration)
                guard relaunched.processIdentifier != ProcessInfo.processInfo.processIdentifier, !relaunched.isTerminated else {
                    throw GuestpadError("The updated Guestpad didn’t launch.")
                }
            } catch {
                try replacement.restore()
                throw error
            }
            replacement.finish()
            NSApp.terminate(nil)
        } catch {
            installError = error.localizedDescription
        }
    }
}
