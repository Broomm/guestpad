#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -m)" != arm64 ]]; then
  printf 'Guestpad currently builds for Apple Silicon.\n' >&2
  exit 1
fi
swift build --scratch-path .build-cache/swift -c release
bin="$(swift build --scratch-path .build-cache/swift -c release --show-bin-path)"
app=dist/Guestpad.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 0755 "$bin/Guestpad" "$app/Contents/MacOS/Guestpad"
xcrun clang -arch arm64 -mmacosx-version-min=15.0 -dynamiclib -O2 \
  -I Sources/GuestpadNative/include Native/ReceiveBridge.c Native/ReceiveHook.S \
  -o "$app/Contents/Resources/libGuestpadReceive.dylib"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.guestpad.Guestpad</string>
<key>CFBundleExecutable</key><string>Guestpad</string>
<key>CFBundleName</key><string>Guestpad</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/Resources/libGuestpadReceive.dylib"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$PWD/$app"
