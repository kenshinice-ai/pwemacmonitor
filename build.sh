#!/bin/zsh
# Build PWE MAC MONITOR.
#
#   ./build.sh              build build/PWE MAC MONITOR.app
#   ./build.sh --run        build, then launch it
#   ./build.sh --dmg        build, then package a drag-to-install disk image
#
# Requires only the Xcode Command Line Tools (`xcode-select --install`). No Xcode project, no
# SwiftPM, no Homebrew, no Rust.
#
# Signing:
#   By default the app is ad-hoc signed, which is enough to run but leaves Gatekeeper warning the
#   people you send it to. Set SIGN_IDENTITY to a "Developer ID Application" certificate to sign
#   properly, and add NOTARY_PROFILE (see `xcrun notarytool store-credentials`) to notarise and
#   staple the disk image, which removes the warning entirely.
#
#     SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#     NOTARY_PROFILE=pwe ./build.sh --dmg

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PWE MAC MONITOR"
# Build outside the project directory. On iCloud Drive the file provider keeps re-applying
# com.apple.FinderInfo to the bundle, and codesign refuses to sign anything carrying it — stripping
# the attribute and signing is a race you lose intermittently. Assemble and sign somewhere plain,
# then copy the finished product back.
WORK="${TMPDIR:-/tmp}/pwe-mac-monitor-build"
APP="$WORK/$APP_NAME.app"
MACOS="$APP/Contents/MacOS"; RES="$APP/Contents/Resources"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

rm -rf "$APP"; mkdir -p "$MACOS" "$RES" build

echo "▸ compiling $APP_NAME $VERSION (arm64, -O)"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  Sources/Core/*.swift Sources/App/*.swift \
  -framework AppKit -framework SwiftUI -framework IOKit -framework ServiceManagement \
  -o "$MACOS/pwemon"

echo "▸ icon"
if [[ ! -f build/AppIcon.icns || Sources/App/BrandMark.swift -nt build/AppIcon.icns ]]; then
  rm -rf "$WORK/AppIcon.iconset"; mkdir -p "$WORK/AppIcon.iconset"
  swiftc -O Tools/icon/main.swift Sources/App/BrandMark.swift -o "$WORK/make_icon" -framework AppKit
  "$WORK/make_icon" "$WORK/icon_1024.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$WORK/icon_1024.png" --out "$WORK/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$WORK/icon_1024.png" --out "$WORK/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$WORK/AppIcon.iconset" -o build/AppIcon.icns
  cp "$WORK/icon_1024.png" build/icon_1024.png
fi

echo "▸ resources"
# ditto --norsrc --noextattr strips the metadata at copy time rather than after the fact.
ditto --norsrc --noextattr --noacl build/AppIcon.icns "$RES/AppIcon.icns"
ditto --norsrc --noextattr --noacl Resources/Fonts "$RES/Fonts"   # ATSApplicationFontsPath
ditto --norsrc --noextattr --noacl Resources/Info.plist "$APP/Contents/Info.plist"
ditto --norsrc --noextattr --noacl THIRD-PARTY-NOTICES.md "$RES/THIRD-PARTY-NOTICES.md"
ditto --norsrc --noextattr --noacl LICENSE "$RES/LICENSE"
ditto --norsrc --noextattr --noacl licenses "$RES/licenses"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

xattr -cr "$APP"
if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "▸ signing as $SIGN_IDENTITY (hardened runtime)"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  echo "▸ ad-hoc signing (set SIGN_IDENTITY for a distributable signature)"
  codesign --force --sign - "$APP" 2>&1 | grep -v "replacing existing" || true
fi
codesign --verify --deep --strict "$APP"

# Hand the finished bundle back to the project directory for convenience.
rm -rf "build/$APP_NAME.app"
ditto "$APP" "build/$APP_NAME.app"
echo "✓ build/$APP_NAME.app"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x pwemon || true
  open "build/$APP_NAME.app"
fi

if [[ "${1:-}" == "--dmg" ]]; then
  DMG="build/PWE-MAC-MONITOR-$VERSION.dmg"
  STAGE="$WORK/dmg"
  echo "▸ packaging $DMG"
  rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/$APP_NAME.app"
  ln -s /Applications "$STAGE/Applications"
  ditto --norsrc --noextattr --noacl docs/INSTALL.txt "$STAGE/Read Me First.txt"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$WORK/out.dmg"
  rm -rf "$STAGE"
  ditto "$WORK/out.dmg" "$DMG"

  if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DMG"
  fi
  if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "▸ notarising (this takes a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "✓ notarised and stapled"
  else
    echo "! not notarised — recipients will need to allow it in System Settings ▸ Privacy & Security"
  fi
  shasum -a 256 "$DMG"
  echo "✓ $DMG"
fi
exit 0
