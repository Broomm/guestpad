import AppKit
import IOKit.hid
import Security

public struct GuestpadError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

public enum PadLink {
    static let bundleID = "com.nimets.PadLink"
    static let driverID = "com.nimets.PadLink.Driver"
    static let controlSerial = "PadLink-Control"
    static let slotSerial = "PadLink-0001"

    public static func installation() throws -> URL {
        let candidates = [
            URL(fileURLWithPath: "/Applications/PadLink.app"),
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        ].compactMap { $0 }
        guard let url = candidates.first(where: { Bundle(url: $0)?.bundleIdentifier == bundleID }),
              let bundle = Bundle(url: url) else {
            throw GuestpadError("Install PadLink separately, then open it and enable its driver.")
        }
        let driver = url.appendingPathComponent("Contents/Library/SystemExtensions/\(driverID).dext")
        guard bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "1.0.0",
              Bundle(url: driver)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "1.0.0" else {
            throw GuestpadError("This Guestpad build supports PadLink 1.0.0.")
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"\(driverID)\" and certificate leaf[subject.OU] = \"NK5DAT4QDQ\""
        guard SecStaticCodeCreateWithPath(driver as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw GuestpadError("Guestpad could not verify PadLink’s driver signature.")
        }
        return url
    }

    public static func check() throws {
        _ = try installation()
        _ = try device(serial: controlSerial, product: "PadLink Control")
    }

    static func device(serial: String, product: String) throws -> IOHIDDevice {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, ["SerialNumber": serial, "Product": product] as CFDictionary)
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []).filter { device in
            let service = IOHIDDeviceGetService(device)
            guard service != 0 else { return false }
            let owner = IORegistryEntryCreateCFProperty(service, "IOUserServerName" as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            return owner == driverID
        }
        guard devices.count == 1, let device = devices.first else {
            let message = serial == controlSerial
                ? "Open PadLink and enable it in System Settings → General → Login Items & Extensions → Driver Extensions."
                : "PadLink did not publish Guestpad’s controller."
            throw GuestpadError(message)
        }
        return device
    }
}

// Uses one idle slot of the separately installed PadLink 1.0.0 driver.
public final class PadLinkOutput {
    private let control: IOHIDDevice
    private let name = "Guestpad"
    private var pad: IOHIDDevice?
    private var ownsSlot = false
    private var lastState: ControllerState?

    public init() throws {
        control = try PadLink.device(serial: PadLink.controlSerial, product: "PadLink Control")
        try checkResult(IOHIDDeviceOpen(control, 0), "Open PadLink control")
        do {
            var mask: [UInt8] = [0, 0]
            var length = mask.count
            try checkResult(IOHIDDeviceGetReport(control, kIOHIDReportTypeFeature, 0xe0, &mask, &length),
                            "Read PadLink slot status")
            guard length == 2, mask == [0xe0, 0] else {
                throw GuestpadError("PadLink already has a controller active. Disconnect it before starting Guestpad.")
            }
            try configure(enabled: true)
            ownsSlot = true
            // Driver registration is asynchronous. This runs on the forwarding queue.
            for _ in 0..<30 {
                if let found = try? PadLink.device(serial: PadLink.slotSerial, product: name),
                   IOHIDDeviceGetProperty(found, "LocationID" as CFString) as? NSNumber == 0x47000000 {
                    try checkResult(IOHIDDeviceOpen(found, 0), "Open the Guestpad controller")
                    pad = found
                    break
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard pad != nil else { throw GuestpadError("The virtual controller did not appear.") }
            try submit(ControllerState())
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    public func submit(_ state: ControllerState) throws {
        guard let pad else { throw GuestpadError("The virtual controller is closed.") }
        guard state != lastState else { return }
        let report = state.padLinkReport
        try checkResult(IOHIDDeviceSetReport(pad, kIOHIDReportTypeOutput, 0xf1, report, report.count),
                        "Send controller input")
        lastState = state
    }

    public func close() {
        if let pad {
            let neutral = ControllerState().padLinkReport
            _ = IOHIDDeviceSetReport(pad, kIOHIDReportTypeOutput, 0xf1, neutral, neutral.count)
            IOHIDDeviceClose(pad, 0)
            self.pad = nil
        }
        if ownsSlot {
            try? configure(enabled: false)
            ownsSlot = false
        }
        IOHIDDeviceClose(control, 0)
    }

    private func configure(enabled: Bool) throws {
        var report: [UInt8] = [0xe1, 0, enabled ? 1 : 0]
        report += name.utf8
        report += Array(repeating: 0, count: 64 - report.count)
        try checkResult(IOHIDDeviceSetReport(control, kIOHIDReportTypeOutput, 0xe1, report, report.count),
                        enabled ? "Enable PadLink slot" : "Disable PadLink slot")
    }

    private func checkResult(_ result: IOReturn, _ operation: String) throws {
        if result != kIOReturnSuccess {
            throw GuestpadError("\(operation) failed (\(String(format: "0x%08x", result))). Check that PadLink’s driver is enabled.")
        }
    }
}
