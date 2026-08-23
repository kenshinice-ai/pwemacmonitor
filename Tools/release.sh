#!/bin/zsh
# Cut a signed, notarised release and publish it everywhere.
#
#   Tools/release.sh 1.0.1
#
# Does, in order: preflight checks · version bump · build · notarise · staple · verify with
# Gatekeeper · tag · GitHub release · Homebrew cask update. Stops at the first failure, and
# refuses to start unless the signing identity and notarisation credentials are both in place —
# there is no point discovering that halfway through.
#
# One-time setup, both of which only you can do (they involve your Apple credentials):
#   1. A "Developer ID Application" certificate in your login keychain.
#   2. xcrun notarytool store-credentials pwe --apple-id <id> --team-id <team>
#      (it prompts for an app-specific password from appleid.apple.com)

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-pwe}"
TAP_REPO="${TAP_REPO:-kenshinice-ai/homebrew-tap}"
REPO="${REPO:-kenshinice-ai/pwemacmonitor}"

if [[ -z "$VERSION" ]]; then
  echo "usage: Tools/release.sh <version>    e.g. Tools/release.sh 1.0.1"
  exit 1
fi

echo "── preflight ─────────────────────────────────────────────"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
if [[ -z "$IDENTITY" ]]; then
  cat <<'MISSING'
✗ No "Developer ID Application" certificate found in your keychain.

  Enrolling in the Developer Program is not enough — the certificate is issued separately:

  1. Keychain Access ▸ menu Keychain Access ▸ Certificate Assistant ▸
     Request a Certificate From a Certificate Authority…
       User Email Address : your Apple ID
       Common Name        : your name or company
       CA Email Address   : leave empty
       Request is         : Saved to disk
     Save the .certSigningRequest file.

  2. https://developer.apple.com/account/resources/certificates/add
       Choose "Developer ID Application", upload the CSR, download the .cer.

  3. Double-click the .cer to add it to your login keychain, then run this again.
MISSING
  exit 1
fi
echo "✓ signing identity: $IDENTITY"

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat <<MISSING
✗ No stored notarisation credentials under the profile "$NOTARY_PROFILE".

  Create an app-specific password at https://appleid.apple.com ▸ Sign-In and Security,
  then run (it will prompt for that password — nothing else needs to see it):

    xcrun notarytool store-credentials $NOTARY_PROFILE \\
      --apple-id <your-apple-id> --team-id <your-team-id>

  Your Team ID is on https://developer.apple.com/account under Membership details.
MISSING
  exit 1
fi
echo "✓ notarisation credentials: profile \"$NOTARY_PROFILE\""

if [[ -n "$(git status --porcelain)" ]]; then
  echo "✗ working tree is dirty — commit or stash first:"
  git status --short
  exit 1
fi
echo "✓ working tree clean"
gh auth status >/dev/null 2>&1 || { echo "✗ gh is not authenticated (run: gh auth login)"; exit 1; }
echo "✓ gh authenticated"

echo
echo "── version $VERSION ──────────────────────────────────────"
BUILD_NUMBER=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" Resources/Info.plist
echo "✓ Info.plist → $VERSION ($BUILD_NUMBER)"

echo
echo "── build, sign, notarise ─────────────────────────────────"
SIGN_IDENTITY="$IDENTITY" NOTARY_PROFILE="$NOTARY_PROFILE" ./build.sh --dmg

DMG="build/PWE-MAC-MONITOR-$VERSION.dmg"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "$SHA  $(basename "$DMG")" > build/SHA256SUMS.txt

echo
echo "── Gatekeeper verdict ────────────────────────────────────"
# The real test: what a stranger's Mac decides when it opens this.
spctl -a -t open --context context:primary-signature -vv "$DMG"
MOUNT=$(hdiutil attach -nobrowse -quiet "$DMG" && echo "/Volumes/PWE MAC MONITOR")
spctl -a -vv "$MOUNT/PWE MAC MONITOR.app"
xcrun stapler validate "$MOUNT/PWE MAC MONITOR.app" || true
hdiutil detach "$MOUNT" -quiet

echo
echo "── publish ───────────────────────────────────────────────"
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/pwe-mac-monitor.rb
git add -A
git commit -q -m "Release $VERSION"
git tag -a "v$VERSION" -m "PWE MAC MONITOR $VERSION"
git push -q origin main
git push -q origin "v$VERSION"
echo "✓ tagged v$VERSION"

gh release create "v$VERSION" "$DMG" build/SHA256SUMS.txt \
  --repo "$REPO" --title "PWE MAC MONITOR $VERSION" --generate-notes \
  --notes-start-tag "$(git describe --tags --abbrev=0 "v$VERSION^" 2>/dev/null || echo "v$VERSION")" \
  || gh release create "v$VERSION" "$DMG" build/SHA256SUMS.txt \
       --repo "$REPO" --title "PWE MAC MONITOR $VERSION" --generate-notes
echo "✓ release published"

TAP_DIR=$(mktemp -d)
git clone -q "https://github.com/$TAP_REPO.git" "$TAP_DIR"
cp Casks/pwe-mac-monitor.rb "$TAP_DIR/Casks/pwe-mac-monitor.rb"
sed -i '' '1,/^cask /{/^#/d;}' "$TAP_DIR/Casks/pwe-mac-monitor.rb"
git -C "$TAP_DIR" add -A
git -C "$TAP_DIR" commit -q -m "pwe-mac-monitor $VERSION"
git -C "$TAP_DIR" push -q origin HEAD
rm -rf "$TAP_DIR"
echo "✓ cask updated in $TAP_REPO"

echo
echo "Done. https://github.com/$REPO/releases/tag/v$VERSION"
echo "  brew install --cask kenshinice-ai/tap/pwe-mac-monitor"
