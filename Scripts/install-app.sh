#!/bin/bash
#
# Build Hipparchus in release and put it in /Applications, so it can be opened
# from Launchpad, Spotlight or a double click.
#
#   Scripts/install-app.sh
#
# The signature is ad-hoc: enough to run on the machine that built it, not
# enough to hand to anyone else. Distributing it would need a Developer ID and
# notarisation, which is a different job from building it.
#
# Build it in release. In debug the contour tracer is about thirty times slower,
# which is the difference between a six-second fetch and a three-minute one.

set -euo pipefail

cd "$(dirname "$0")/.."

DESTINATION="${1:-/Applications}"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

if ! command -v xcodegen >/dev/null; then
    echo "error: xcodegen is not installed — brew install xcodegen" >&2
    exit 1
fi

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

# Replaced rather than merged: copying over a previous install leaves whatever
# the old bundle had that the new one does not, which is how an app ends up
# running code nobody can find in the source.
echo "Installing to $DESTINATION/Hipparchus.app…"
rm -rf "${DESTINATION:?}/Hipparchus.app"
cp -R "$BUILT" "$DESTINATION/Hipparchus.app"

codesign --verify --strict "$DESTINATION/Hipparchus.app"

echo
echo "Installed. Open it from Launchpad, or:"
echo "    open -a Hipparchus"
echo
echo "The same binary answers the headless flags, which is how output gets"
echo "checked without a window:"
echo "    '$DESTINATION/Hipparchus.app/Contents/MacOS/Hipparchus' --bbox 25.32,36.33,25.50,36.48 --render-to out.png"
