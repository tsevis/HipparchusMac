#!/bin/bash
#
# Build Hipparchus in release and wrap it in a disk image.
#
#   Scripts/make-dmg.sh            → dist/Hipparchus-<version>-<sha>.dmg
#
# **Read this before sending the result to anyone.** The app is signed
# ad-hoc — no Developer ID, no notarisation — so on any Mac other than the one
# that built it, Gatekeeper refuses to open it: a downloaded disk image carries
# a quarantine flag, and macOS will say the app "cannot be opened because the
# developer cannot be verified". The recipient has to right-click the app and
# choose Open, or clear the flag by hand:
#
#     xattr -dr com.apple.quarantine /Applications/Hipparchus.app
#
# That is a reasonable thing to ask of yourself and an unreasonable thing to ask
# of anyone else. Proper distribution needs an Apple Developer account, a
# Developer ID certificate, `codesign --options runtime` with that identity and
# `notarytool submit --wait` afterwards. This script does none of that, and says
# so rather than producing something that looks distributable and is not.
#
# The image is the plain layout: the app and a link to /Applications, so it can
# be dragged across. No custom background or icon placement — those need Finder
# automation this environment cannot drive.

set -euo pipefail

cd "$(dirname "$0")/.."

OUTPUT_DIR="${1:-dist}"
STAGING="$(mktemp -d)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING" "$BUILD_DIR"' EXIT

command -v xcodegen >/dev/null || { echo "error: xcodegen is not installed — brew install xcodegen" >&2; exit 1; }

echo "Generating the project…"
xcodegen generate --spec App/project.yml >/dev/null

echo "Building in release…"
xcodebuild \
    -project App/HipparchusMac.xcodeproj \
    -scheme HipparchusMac \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    build >/dev/null

BUILT="$BUILD_DIR/Build/Products/Release/Hipparchus.app"
test -d "$BUILT" || { echo "error: the build produced no app" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
# The commit is in the filename because an ad-hoc build has no other way to say
# which source it came from.
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY=""
git diff --quiet HEAD 2>/dev/null || DIRTY="-dirty"
NAME="Hipparchus-${VERSION}-${SHA}${DIRTY}"

echo "Staging the image…"
cp -R "$BUILT" "$STAGING/Hipparchus.app"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$OUTPUT_DIR"
IMAGE="$OUTPUT_DIR/$NAME.dmg"
rm -f "$IMAGE"

echo "Creating $IMAGE…"
hdiutil create \
    -volname "Hipparchus" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$IMAGE" >/dev/null

hdiutil verify "$IMAGE" >/dev/null
echo

echo "Wrote $IMAGE ($(du -h "$IMAGE" | cut -f1))"
echo
echo "Signed ad-hoc: it opens on this Mac. On any other Mac, Gatekeeper will"
echo "refuse it until the reader right-clicks the app and chooses Open, because"
echo "there is no Developer ID and no notarisation. See the notes at the top of"
echo "this script before sending it to anyone."
