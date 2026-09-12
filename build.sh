#!/bin/zsh
# Build PWE Monitor.
#
#   ./build.sh              build build/PWE Monitor.app
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

# The bundle, and therefore what Finder shows. Renaming only CFBundleDisplayName does not do it:
# Finder reports kMDItemDisplayName from the filename, so the app would have said "PWE Monitor" in
# its own interface and "PWE MAC MONITOR" everywhere the system named it.
#
# The DMG filename, the cask token, the bundle identifier and the repository all keep the old
# spelling on purpose. Those are addresses — the site's deploy.sh fetches PWE-MAC-MONITOR-x.y.z.dmg
# by name, and an installed cask uninstalls itself using the definition saved when it was
# installed. Renaming an address strands whoever already has it.
APP_NAME="PWE Monitor"
# Build outside the project directory. On iCloud Drive the file provider keeps re-applying
# com.apple.FinderInfo to the bundle, and codesign refuses to sign anything carrying it — stripping
# the attribute and signing is a race you lose intermittently. Assemble and sign somewhere plain,
# then copy the finished product back.
WORK="${TMPDIR:-/tmp}/pwe-mac-monitor-build"
APP="$WORK/$APP_NAME.app"
MACOS="$APP/Contents/MacOS"; RES="$APP/Contents/Resources"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
# Use a Developer ID Application certificate automatically when one is installed. Without it the
# build falls back to an ad-hoc signature, which runs but makes Gatekeeper warn whoever you send it
# to. Set SIGN_IDENTITY to override the choice, or to "-" to force ad-hoc.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
[[ "$SIGN_IDENTITY" == "-" ]] && SIGN_IDENTITY=""

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

echo "▸ strings"
# en.lproj is generated from the English written at each L(...) call site; zh-Hans.lproj is the
# only hand-maintained table. Fails the build on a key that is used but not translated, so a
# half-translated panel cannot ship.
swiftc -O Tools/loccheck/main.swift -o "$WORK/loccheck"
"$WORK/loccheck" .

echo "▸ resources"
# ditto --norsrc --noextattr strips the metadata at copy time rather than after the fact.
ditto --norsrc --noextattr --noacl build/AppIcon.icns "$RES/AppIcon.icns"
for lproj in Resources/*.lproj; do
  ditto --norsrc --noextattr --noacl "$lproj" "$RES/$(basename "$lproj")"
done
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
  echo "▸ ad-hoc signing — no Developer ID Application certificate found"
  echo "  Recipients will have to allow the app in System Settings ▸ Privacy & Security."
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
  ditto --norsrc --noextattr --noacl docs/INSTALL.txt "$STAGE/Read Me First 请先阅读.txt"
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
    spctl -a -t open --context context:primary-signature -vv "$DMG" || true
    echo "✓ notarised and stapled — opens with no warning on any Mac"
  elif [[ -n "$SIGN_IDENTITY" ]]; then
    echo "! signed but not notarised. Store credentials once with:"
    echo "    xcrun notarytool store-credentials pwe --apple-id <id> --team-id <team>"
    echo "  then rebuild with NOTARY_PROFILE=pwe"
  else
    echo "! not signed for distribution — recipients must allow it in Privacy & Security"
  fi
  shasum -a 256 "$DMG"
  echo "✓ $DMG"
fi
exit 0
