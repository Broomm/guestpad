// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Guestpad", platforms: [.macOS(.v15)], products: [
    .executable(name: "Guestpad", targets: ["Guestpad"]),
    .executable(name: "guestpad-check", targets: ["GuestpadCheck"])
], targets: [
    .target(name: "GuestpadNative", publicHeadersPath: "include"),
    .target(name: "GuestpadCore", dependencies: ["GuestpadNative"]),
    .executableTarget(name: "Guestpad", dependencies: ["GuestpadCore"]),
    .executableTarget(name: "GuestpadCheck", dependencies: ["GuestpadCore"]),
    .testTarget(name: "GuestpadCoreTests", dependencies: ["GuestpadCore"])
], swiftLanguageModes: [.v5])
