#!/bin/bash
#
# Build Hipparchus in release and wrap it in a disk image.
#
#   Scripts/make-dmg.sh            → dist/Hipparchus-<version>-<sha>.dmg
#
# **Read this before sending the result to anyone.**
#
# This script signs and notarises when it can, and says what is missing when it
# cannot. With a "Developer ID Application" certificate in the keychain and
# notary credentials stored under the profile `hipparchus-notary`, it signs the
# app and the image, submits for notarisation, waits, and staples the ticket —
# after which anyone can download the result from GitHub and double-click it.
#
# Without those, everything below still applies. The app is signed
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

# --------------------------------------------------------------------------
# Developer ID and notarisation, when they are available
#
# Whether a downloader sees a warning is decided by two things, and only the
# second is about this script. The first is the `com.apple.quarantine`
# attribute, set by whatever *received* the file: a stick or an rsync sets
# nothing and the app opens with no fuss whatever it is signed with, which is
# why an ad-hoc build can be handed round and appear to be fine. A browser
# download — from GitHub, say — does set it, and then Gatekeeper has an opinion.
#
# The steps below are what change that opinion. They need an Apple Developer
# account, a "Developer ID Application" certificate in the keychain, and
# credentials stored once with `notarytool store-credentials`. None of that can
# live in a repository, so the script looks for them and says what is missing
# rather than failing.
# --------------------------------------------------------------------------

# `|| true` is load-bearing: with `set -euo pipefail` a grep that matches
# nothing fails the pipeline, fails the substitution, and ends the script —
# silently, after "Staging the image…", which is a maddening way to learn that
# you have no certificate.
IDENTITY="${DEVELOPER_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-hipparchus-notary}"
NOTARISED=false

if [ -n "$IDENTITY" ]; then
    echo "Signing with: $IDENTITY"
    # Deep, and the runtime hardened — notarisation refuses anything less.
    # Nested code first, the app last, which is the order codesign requires.
    codesign --force --deep --options runtime --timestamp \
        --sign "$IDENTITY" "$STAGING/Hipparchus.app"
    codesign --verify --strict --verbose=2 "$STAGING/Hipparchus.app" 2>&1 | tail -2
else
    echo "No Developer ID certificate found — leaving the ad-hoc signature in place."
fi

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

if [ -n "$IDENTITY" ]; then
    # The image is signed too, so it is the *image* Gatekeeper trusts rather
    # than only what is inside it.
    codesign --force --sign "$IDENTITY" --timestamp "$IMAGE"

    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "Notarising — this takes a few minutes and Apple decides when…"
        if xcrun notarytool submit "$IMAGE" \
            --keychain-profile "$NOTARY_PROFILE" --wait; then
            # Stapling writes the ticket into the image, so it opens on a Mac
            # that is offline or behind a firewall that blocks Apple's check.
            xcrun stapler staple "$IMAGE" && NOTARISED=true
        else
            echo "warning: notarisation failed — the image is signed but not notarised" >&2
        fi
    else
        echo "No notary credentials for profile '$NOTARY_PROFILE'. Store them once with:"
        echo "    xcrun notarytool store-credentials $NOTARY_PROFILE \\"
        echo "        --apple-id <your-apple-id> --team-id <your-team-id>"
        echo "  (it asks for an app-specific password from appleid.apple.com)"
    fi
fi

echo
echo "Wrote $IMAGE ($(du -h "$IMAGE" | cut -f1))"
echo
if [ "$NOTARISED" = true ]; then
    echo "Signed with a Developer ID and notarised. Someone downloading this from"
    echo "GitHub can open it by double-clicking, with no warning and no advice"
    echo "needed from you."
    spctl -a -vvv -t open --context context:primary-signature "$IMAGE" 2>&1 | tail -2
elif [ -n "$IDENTITY" ]; then
    echo "Signed with a Developer ID but NOT notarised, which a browser download"
    echo "still refuses. Store notary credentials and run this again."
else
    echo "Signed ad-hoc. Handed over on a stick or through a sync folder it opens"
    echo "normally, because nothing marked it as downloaded. Fetched from GitHub in"
    echo "a browser it is quarantined, and the reader must right-click and choose"
    echo "Open. To remove that step entirely you need an Apple Developer account, a"
    echo "Developer ID certificate and notarisation — see the notes at the top."
fi
