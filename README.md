# Guestpad

Guestpad forwards one Parsec guest’s gamepad to a Mac as a DualShock 4. The window shows the current button, stick and trigger state.

This preview targets Apple Silicon and requires macOS 15 or later, Parsec launcher 150.101.1 with the tested 150-105c core, and PadLink 1.0.0. The runtime checks the Parsec core hash and the signature of the installed PadLink driver. A version change may require an updated Guestpad bridge.

## Setup

1. Install [Parsec](https://parsec.app/) and [PadLink](https://padlink.nimets.com/) separately. Open PadLink and enable its driver in **System Settings → General → Login Items & Extensions → Driver Extensions**. Guestpad detects the existing installation and uses one idle driver slot.
2. Open Guestpad. If Parsec needs preparation, choose **Prepare Parsec**. This quits Parsec once, stages a copy with Guestpad’s bridge in its launcher, signs it with debugging enabled, exchanges it with the installed bundle, and resets Screen Recording, Accessibility and Microphone grants for Parsec. The original bundle is saved in the installation directory at `.Guestpad-Parsec-Original/Parsec.original`. macOS may require App Management permission to replace the app and ask you to grant Parsec’s permissions again.
3. Open the prepared Parsec app normally. It loads the bridge at launch. Choose **Start Forwarding** in Guestpad at any point, including during a session. If Parsec is closed, Guestpad opens it. Connect one guest and enable its **Gamepad** permission in Parsec. Guestpad publishes one virtual controller after it sees controller input.
4. Choose **Stop Forwarding** or quit Guestpad to release the virtual controller. The Parsec host stays open. Guestpad can reopen and resume forwarding without a host restart. The bridge stays loaded in prepared Parsec and sends input only while a local forwarding listener is active.

Upgrading from Guestpad 0.1.0 requires one more preparation so future Parsec launches load the embedded bridge. Wait until your current session has ended before preparing.

Disconnect any PadLink controller before starting Guestpad. When multiple peers are observed, Guestpad releases the virtual device and waits until one peer remains. If the physical controller reconnects with a fresh ID, Guestpad switches to its new reports after the old ID goes quiet. The virtual controller stays present and returns to neutral while input is unavailable.

PadLink supplies the DualShock 4 identity. Its version-specific HID report interface is undocumented. The app contains Guestpad’s own report writer and Parsec receive bridge.

To restore Parsec, quit both apps and move the saved original bundle back to the installation path, using its original `Parsec.app` name. macOS may ask you to reauthorize Parsec after restoring the signature. Keep the backup until the original app is running again.

## Controller preview

The live preview matches the DualShock 4 that PadLink presents to macOS. Trigger bars and percentages use the same linear input value that Guestpad forwards.

## Face button calibration

While a controller is forwarding, choose **Calibrate Face Buttons**. Press and release each physical face button in order, moving counterclockwise from the bottom: bottom, right, top, left. Guestpad assigns them to Cross, Circle, Triangle, and Square respectively. The mapping saves when you release the fourth button. Calibration pauses game input and rejects duplicate or simultaneous face presses. Cancel keeps the previous mapping.

## Updates

Download Guestpad from [GitHub Releases](https://github.com/Broomm/guestpad/releases) and move it to Applications. Guestpad checks for a new release at launch and periodically while the window is open. When a newer build is available, click **Update to …** to verify, install, and relaunch it. If macOS blocks replacement, the error dialog links to the release for manual installation.

## Build

Run `./scripts/build.sh` with the Apple command line tools installed. The result is `dist/Guestpad.app`. The script verifies the ad-hoc signature before returning the build. The package uses the macOS SDK and contains no package dependencies.

Run `swift test --scratch-path .build-cache/swift` with XCTest available to check report mapping and guest selection. The `guestpad-check` executable built by SwiftPM can send a brief button and stick sequence through the installed driver. Run it with PadLink idle and Guestpad forwarding off.

Run `./scripts/package.sh` to build a ZIP and SHA-256 checksum in `dist/`. The packager extracts the ZIP and verifies the app signature before placing it in `dist/`.

The [macOS workflow](.github/workflows/macos.yml) runs the Swift tests on Apple Silicon, builds the app, and uploads the ZIP and checksum as the `Guestpad-macOS-arm64` artifact. The artifact is an ad-hoc signed preview. Parsec and PadLink are separate runtime prerequisites for manual integration testing.

Push a tag such as `v0.4.0` to publish the verified ZIP and checksum to GitHub Releases. The tag must match `CFBundleShortVersionString` in `scripts/build.sh`.
