#!/bin/bash
#
# Run the layout tests.
#
#   Scripts/ui-test.sh            # asks first
#   Scripts/ui-test.sh --yes      # for CI, or for somebody who already knows
#
# THESE OPEN REAL WINDOWS. XCUITest works by launching the application and
# driving it, so this takes over the screen of whoever runs it for a minute or
# two: windows appear, controls are clicked, and the app quits again. That is
# unlike every other test in this repository, all of which are headless, and it
# is why this is a script with a prompt rather than something `swift test`
# reaches.
#
# Do not run it on somebody's machine without asking them.
#
# The app under test is launched with --state-directory pointing at a throwaway
# name, so the session, preferences, saved styles and cache of the *real*
# installed app are not touched. There is a test that asserts exactly that; if
# it ever fails, stop and fix it before running the rest.

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIRMED="no"
for argument in "$@"; do
    case "$argument" in
        --yes|-y) CONFIRMED="yes" ;;
        *) echo "usage: $0 [--yes]" >&2; exit 2 ;;
    esac
done

if [ "$CONFIRMED" != "yes" ]; then
    echo
    echo "This opens real windows and drives them, on this desktop, for a minute"
    echo "or two. Everything else in this repository is headless; this is not."
    echo
    printf "Run the layout tests? [y/N] "
    read -r answer
    case "$answer" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "Not run."; exit 0 ;;
    esac
fi

if ! command -v xcodegen >/dev/null; then
    echo "error: xcodegen is not installed — brew install xcodegen" >&2
    exit 1
fi

echo "Generating the project…"
xcodegen generate --spec App/project.yml >/dev/null

echo "Running the layout tests…"
xcodebuild test \
    -project App/HipparchusMac.xcodeproj \
    -scheme HipparchusUITests \
    -configuration Debug \
    -destination 'platform=macOS' \
    2>&1 | grep -Ev '^\s*$' | tail -40
