import CryptoKit
import Darwin
import Foundation
import Security

public struct GuestpadRelease: Equatable, Sendable {
    public let version: String
    let downloadURL: URL
    let byteCount: Int
    let digest: String
}

public enum GuestpadUpdates {
    public static let releasesPage = URL(string: "https://github.com/Broomm/guestpad/releases/latest")!
    private static let feed = URL(string: "https://api.github.com/repos/Broomm/guestpad/releases/latest")!
    private static let bundleID = "app.guestpad.Guestpad"
    private static let maximumArchiveBytes = 32 * 1024 * 1024

    public static func latest(after installedVersion: String) async throws -> GuestpadRelease? {
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (status, body) = try await fetch(request, limit: 1_048_576, allowMissing: true)
        guard status != 404 else { return nil }
        return try selectRelease(from: body, after: installedVersion)
    }

    static func selectRelease(from body: Data, after installedVersion: String) throws -> GuestpadRelease? {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: body)
        guard !release.draft, !release.prerelease, release.tag_name.hasPrefix("v"),
              let installed = versionParts(installedVersion) else { return nil }
        let version = String(release.tag_name.dropFirst())
        guard let parts = versionParts(version), installed.lexicographicallyPrecedes(parts) else { return nil }

        let name = "Guestpad-\(version)-macOS-arm64.zip"
        let expectedURL = URL(string: "https://github.com/Broomm/guestpad/releases/download/v\(version)/\(name)")!
        let matches = release.assets.filter { $0.name == name && $0.state == "uploaded" }
        guard matches.count == 1, let asset = matches.first,
              asset.browser_download_url == expectedURL,
              (1...maximumArchiveBytes).contains(asset.size),
              let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw GuestpadError("GitHub doesn’t have a verified Apple Silicon archive for Guestpad \(version).")
        }
        let hex = String(digest.dropFirst("sha256:".count))
        guard hex.utf8.count == 64, hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw GuestpadError("GitHub returned an invalid update checksum.")
        }
        return GuestpadRelease(version: version, downloadURL: expectedURL, byteCount: asset.size, digest: hex)
    }

    public static func install(_ release: GuestpadRelease, replacing bundle: URL,
                               installedVersion: String) async throws -> GuestpadReplacement {
        let (_, bytes) = try await fetch(URLRequest(url: release.downloadURL), limit: release.byteCount)
        return try await Task.detached {
            try replaceBundle(with: bytes, release: release, at: bundle, installedVersion: installedVersion)
        }.value
    }

    static func replaceBundle(with bytes: Data, release: GuestpadRelease, at bundle: URL,
                              installedVersion: String) throws -> GuestpadReplacement {
        guard bytes.count == release.byteCount,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == release.digest else {
            throw GuestpadError("The downloaded archive doesn’t match the GitHub release checksum.")
        }
        guard let installed = versionParts(installedVersion), let next = versionParts(release.version),
              installed.lexicographicallyPrecedes(next) else {
            throw GuestpadError("The update is no newer than the installed app.")
        }
        let target = bundle.standardizedFileURL.resolvingSymlinksInPath()
        guard target.pathExtension == "app", !target.pathComponents.contains("AppTranslocation") else {
            throw GuestpadError("Move Guestpad to Applications before updating.")
        }
        let fm = FileManager.default
        let folder = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                appropriateFor: target, create: true).resolvingSymlinksInPath()
        do {
            let archive = folder.appendingPathComponent("Guestpad.zip")
            try bytes.write(to: archive, options: .withoutOverwriting)
            let extract = Process()
            extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            extract.arguments = ["-x", "-k", archive.path, folder.path]
            extract.standardOutput = FileHandle.nullDevice
            extract.standardError = FileHandle.nullDevice
            try extract.run()
            extract.waitUntilExit()
            guard extract.terminationStatus == 0 else {
                throw GuestpadError("Couldn’t open the Guestpad update archive.")
            }
            let staged = folder.appendingPathComponent("Guestpad.app")
            try verify(staged, version: release.version)
            try verify(target, version: installedVersion)
            guard renamex_np(target.path, staged.path, UInt32(RENAME_SWAP)) == 0 else {
                throw GuestpadError("macOS couldn’t replace Guestpad. Check App Management permission or install the release from GitHub.")
            }
            return GuestpadReplacement(installed: target, backup: staged, folder: folder)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    private static func verify(_ url: URL, version: String) throws {
        let info = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        let properties = try PropertyListSerialization.propertyList(from: info, options: [], format: nil) as? [String: Any]
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "identifier \"\(bundleID)\""
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard url.resolvingSymlinksInPath().path == url.path,
              properties?["CFBundleIdentifier"] as? String == bundleID,
              properties?["CFBundleShortVersionString"] as? String == version,
              Bundle(url: url)?.executableArchitectures?.contains(NSNumber(value: 0x0100000c)) == true,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw GuestpadError("Guestpad couldn’t verify the app’s identity, version, or signature.")
        }
    }

    private static func versionParts(_ version: String) -> [Int]? {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = components.compactMap { Int($0) }
        guard components.count == 3, numbers.count == 3, numbers.allSatisfy({ $0 >= 0 }),
              numbers.map(String.init).joined(separator: ".") == version else { return nil }
        return numbers
    }

    private static func fetch(_ request: URLRequest, limit: Int, allowMissing: Bool = false) async throws -> (Int, Data) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: GitHubRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if allowMissing, response.statusCode == 404 { return (404, Data()) }
        guard response.statusCode == 200, response.expectedContentLength <= Int64(limit) else {
            throw GuestpadError("GitHub couldn’t provide the update (HTTP \(response.statusCode)).")
        }
        var data = Data()
        for try await byte in stream {
            guard data.count < limit else { throw GuestpadError("The update download exceeded its expected size.") }
            data.append(byte)
        }
        return (200, data)
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let state: String
            let browser_download_url: URL
            let size: Int
            let digest: String?
        }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private final class GitHubRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let hosts = ["github.com", "api.github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
            guard let url = request.url, url.scheme == "https", url.port == nil, url.user == nil, url.password == nil,
                  let host = url.host, hosts.contains(host) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}

public struct GuestpadReplacement: Sendable {
    public let installed: URL
    let backup: URL
    let folder: URL

    public func finish() {
        try? FileManager.default.removeItem(at: folder)
    }

    public func restore() throws {
        guard renamex_np(installed.path, backup.path, UInt32(RENAME_SWAP)) == 0 else {
            throw GuestpadError("Couldn’t restore the previous Guestpad. Its backup is at \(backup.path).")
        }
        finish()
    }
}
