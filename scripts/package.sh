#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh
app=dist/Guestpad.app
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Invalid Guestpad version: %s\n' "$version" >&2
  exit 1
fi

archive="Guestpad-$version-macOS-arm64.zip"
stage="$(mktemp -d "$PWD/.build-cache/package.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/$archive"
/usr/bin/unzip -tq "$stage/$archive"
/usr/bin/ditto -x -k "$stage/$archive" "$stage/verify"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$stage/verify/Guestpad.app"
(
  cd "$stage"
  /usr/bin/shasum -a 256 "$archive" > "$archive.sha256"
)
mv -f "$stage/$archive" "$stage/$archive.sha256" dist/
printf '%s\n' "$PWD/dist/$archive"
