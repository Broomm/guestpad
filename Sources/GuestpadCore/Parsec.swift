import AppKit
import CryptoKit
import Security

public struct Parsec: Sendable {
    public let url: URL
    public let prepared: Bool
    public static let bundleID = "tv.parsec.www"
    private static let expectedCore = "26a0fe52fd701ee1a75f1f90bcc0b0eb678e6b133df37b7732b0d220388da0ea"

    public static func inspect() throws -> Parsec {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/Parsec.app"),
            home.appendingPathComponent("Applications/Parsec.app"),
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        ].compactMap { $0 }
        guard let url = candidates.first(where: { Bundle(url: $0)?.bundleIdentifier == bundleID }),
              let bundle = Bundle(url: url) else { throw GuestpadError("Parsec is not installed.") }
        guard bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "150.101.1" else {
            throw GuestpadError("This Guestpad build supports Parsec 150.101.1.")
        }
        let core = home.appendingPathComponent(".parsec/parsecd-150-105c.dylib")
        guard let bytes = try? Data(contentsOf: core, options: .mappedIfSafe),
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expectedCore else {
            throw GuestpadError("The supported Parsec core is missing or has changed. Guestpad supports core 150-105c with the verified build hash.")
        }
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let details = information as? [String: Any] else {
            throw GuestpadError("The installed Parsec signature could not be verified.")
        }
        let flags = (details[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let adHoc = flags & 0x2 != 0 && flags & 0x10000 == 0
        guard adHoc || details[kSecCodeInfoTeamIdentifier as String] as? String == "Y9MY52XZDB" else {
            throw GuestpadError("Parsec’s signing identity is not recognized.")
        }
        let launcher = try Data(contentsOf: url.appendingPathComponent("Contents/MacOS/parsecd"))
        let embedded = url.appendingPathComponent("Contents/Frameworks/\(ParsecLauncher.bridgeName)")
        let prepared = adHoc && ParsecLauncher.loadsBridge(launcher) && FileManager.default.fileExists(atPath: embedded.path)
        return Parsec(url: url, prepared: prepared)
    }

    @MainActor public func quitRunning() async throws {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
        for app in apps where !app.isTerminated {
            guard app.bundleURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() else {
                throw GuestpadError("Quit the other running copy of Parsec and try again.")
            }
            _ = app.terminate()
        }
        for _ in 0..<40 {
            if apps.allSatisfy(\.isTerminated) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw GuestpadError("Quit Parsec from its menu and try again.")
    }

    @MainActor public func launchIfNeeded() async throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .filter { !$0.isTerminated }
        if !running.isEmpty {
            guard running.count == 1,
                  running[0].bundleURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() else {
                throw GuestpadError("Another copy of Parsec is running. Use the prepared installation.")
            }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    // Stage on the same volume, then exchange the two bundles atomically.
    public func prepare(bridge: URL) throws {
        guard !prepared else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty else {
            throw GuestpadError("Quit Parsec before preparing it.")
        }
        let fm = FileManager.default
        let backup = url.deletingLastPathComponent().appendingPathComponent(".Guestpad-Parsec-Original")
        if !fm.fileExists(atPath: backup.path) {
            try fm.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let attributes = try fm.attributesOfItem(atPath: backup.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              attributes[.ownerAccountID] as? NSNumber == NSNumber(value: getuid()),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw GuestpadError("Guestpad could not verify the Parsec backup directory.")
        }
        let lock = open(backup.appendingPathComponent("prepare.lock").path,
                        O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw GuestpadError("Could not lock the Parsec backup directory.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw GuestpadError("Parsec is already being prepared by another Guestpad instance.")
        }
        let original = backup.appendingPathComponent("Parsec.original")
        let stage = fm.fileExists(atPath: original.path)
            ? backup.appendingPathComponent("Parsec.previous-\(UUID().uuidString)")
            : original
        var exchanged = false
        defer { if !exchanged { try? fm.removeItem(at: stage) } }
        try Self.stagePreparedCopy(from: url, at: stage, bridge: bridge)
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).allSatisfy(\.isTerminated) else {
            throw GuestpadError("Parsec opened during preparation. Quit it and try again.")
        }
        guard renamex_np(url.path, stage.path, UInt32(RENAME_SWAP)) == 0 else {
            throw GuestpadError("macOS could not replace Parsec. Check Guestpad’s App Management permission and your access to its installation folder.")
        }
        exchanged = true
        for permission in ["ScreenCapture", "Accessibility", "Microphone"] {
            do { try Self.run("/usr/bin/tccutil", ["reset", permission, Self.bundleID]) }
            catch { throw GuestpadError("Parsec was prepared and the original was saved, but macOS could not reset \(permission). Review Parsec’s permissions in System Settings.") }
        }
    }

    static func stagePreparedCopy(from source: URL, at stage: URL, bridge: URL) throws {
        let fm = FileManager.default
        try fm.copyItem(at: source, to: stage)
        let launcher = stage.appendingPathComponent("Contents/MacOS/parsecd")
        let contents = try Data(contentsOf: launcher)
        let modified = try ParsecLauncher.addingBridge(to: contents)
        try modified.write(to: launcher)
        let frameworks = stage.appendingPathComponent("Contents/Frameworks")
        try fm.createDirectory(at: frameworks, withIntermediateDirectories: true)
        let embedded = frameworks.appendingPathComponent(ParsecLauncher.bridgeName)
        if fm.fileExists(atPath: embedded.path) { try fm.removeItem(at: embedded) }
        try fm.copyItem(at: bridge, to: embedded)
        try run("/usr/bin/codesign", ["--verify", "--strict", embedded.path])
        let entitlements = stage.deletingLastPathComponent().appendingPathComponent("Guestpad-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["com.apple.security.get-task-allow": true], format: .xml, options: 0
        )
        try data.write(to: entitlements, options: .withoutOverwriting)
        defer { try? fm.removeItem(at: entitlements) }
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "0", "--entitlements", entitlements.path, stage.path])
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", stage.path])
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GuestpadError("\(process.executableURL!.lastPathComponent) failed (\(process.terminationStatus)).") }
    }
}
