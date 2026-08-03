#!/bin/bash
#
# Keep the test count in README.md true.
#
#   Scripts/update-test-count.sh           rewrite it
#   Scripts/update-test-count.sh --check   say whether it is stale, write nothing
#
# The number went stale three times in one day, in three consecutive commits,
# because it is a fact about every commit and nothing checked it. A figure that
# is wrong more often than it is right is worse than no figure: it teaches a
# reader that the numbers in this README are decorative, and most of them are
# not — they are the whole argument.
#
# The count comes from `swift test --list-tests`, which is the runner's own
# answer and needs no test to be executed. Counting `func test` with grep would
# be quicker and would quietly disagree with it: a disabled test still has its
# function, and a parameterised one has several cases behind a single name.
#
# `--check` is for before a commit, and exits non-zero when it disagrees, so it
# can be wired to something that runs on its own if this keeps happening.

set -euo pipefail

cd "$(dirname "$0")/.."

README="README.md"
OPEN="<!--tests-->"
CLOSE="<!--/tests-->"

check_only=false
if [ "${1:-}" = "--check" ]; then
    check_only=true
elif [ -n "${1:-}" ]; then
    echo "usage: $0 [--check]" >&2
    exit 2
fi

grep -q "$OPEN" "$README" || {
    echo "error: $README has no $OPEN marker to fill in" >&2
    exit 1
}

# `--list-tests` builds if it has to, so let it say so rather than appearing to
# hang on a cold checkout.
echo "Listing tests…" >&2
counted="$(swift test --list-tests 2>/dev/null | grep -c .)"

if [ "$counted" -lt 1 ]; then
    echo "error: the runner listed no tests at all — is the package building?" >&2
    exit 1
fi

# `|` as the delimiter, not `/`: the closing marker is `<!--/tests-->` and BSD
# sed reads the slash in it as the end of the expression.
stated="$(sed -n "s|.*$OPEN\([0-9]*\)$CLOSE.*|\1|p" "$README" | head -1)"

if [ "$stated" = "$counted" ]; then
    echo "$README says $counted tests, and there are $counted."
    exit 0
fi

if [ "$check_only" = true ]; then
    echo "$README says ${stated:-nothing}, and there are $counted." >&2
    echo "Run $0 to fix it." >&2
    exit 1
fi

# Only between the markers, so a number that happens to appear elsewhere in the
# prose is left alone.
# Braced delimiters for the same reason as the sed above: both markers contain
# a slash, and both `s///` and `s|||` would end early on it.
perl -pi -e "s{\Q$OPEN\E[0-9]*\Q$CLOSE\E}{$OPEN$counted$CLOSE}g" "$README"
echo "$README: ${stated:-nothing} → $counted"
