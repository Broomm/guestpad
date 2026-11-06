import Foundation
import XCTest
@testable import GuestpadCore

final class GuestpadUpdatesTests: XCTestCase {
    func testOnlyNewerStableReleaseIsOffered() throws {
        let release = try GuestpadUpdates.selectRelease(from: response(), after: "0.3.9")
        XCTAssertEqual(release?.version, "0.4.0")
        XCTAssertNil(try GuestpadUpdates.selectRelease(from: response(), after: "0.4.0"))
        XCTAssertNil(try GuestpadUpdates.selectRelease(from: response(), after: "0.10.0"))
        XCTAssertNil(try GuestpadUpdates.selectRelease(from: response(prerelease: true), after: "0.3.9"))
    }

    func testNewerReleaseRequiresAnArchiveFromGuestpadsReleaseAndValidDigest() throws {
        XCTAssertThrowsError(try GuestpadUpdates.selectRelease(
            from: response(url: "https://github.com/someone/guestpad/releases/download/v0.4.0/Guestpad-0.4.0-macOS-arm64.zip"),
            after: "0.3.9"
        ))
        XCTAssertThrowsError(try GuestpadUpdates.selectRelease(from: response(digest: "sha256:invalid"), after: "0.3.9"))
    }

    func testMismatchedArchiveIsRejectedBeforeAccessingInstalledApp() throws {
        let release = try XCTUnwrap(GuestpadUpdates.selectRelease(from: response(), after: "0.3.9"))
        let missing = URL(fileURLWithPath: "/nonexistent/Guestpad.app")
        XCTAssertThrowsError(try GuestpadUpdates.replaceBundle(
            with: Data(repeating: 0, count: release.byteCount), release: release, at: missing, installedVersion: "0.3.9"
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("checksum"))
        }
    }

    private func response(
        url: String = "https://github.com/Broomm/guestpad/releases/download/v0.4.0/Guestpad-0.4.0-macOS-arm64.zip",
        digest: String = "sha256:" + String(repeating: "0", count: 64),
        prerelease: Bool = false
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": "v0.4.0",
            "draft": false,
            "prerelease": prerelease,
            "assets": [[
                "name": "Guestpad-0.4.0-macOS-arm64.zip",
                "state": "uploaded",
                "browser_download_url": url,
                "size": 1024,
                "digest": digest
            ]]
        ])
    }
}
