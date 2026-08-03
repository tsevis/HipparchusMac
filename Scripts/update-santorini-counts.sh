#!/bin/bash
#
# Keep the Santorini layer counts in README.md true.
#
#   Scripts/update-santorini-counts.sh           rewrite them
#   Scripts/update-santorini-counts.sh --check   say whether they are stale
#
# These are the README's one claim about what actually arrives in Illustrator,
# and they were typed. Three of the four were wrong by the time anyone looked:
# the bathymetry figure predated EMODnet, and the summit-label figure counted
# `<text>` elements rather than labels — every label is written twice, once for
# its halo and once for its fill, so 34 elements are 17 labels.
#
# **Unlike `update-test-count.sh`, this one needs the network** — it draws a real
# Santorini from real elevation. It is therefore not something to wire into a
# pre-commit hook; run it when the pipeline changes, or after an upstream source
# does. A warm cache makes it quick.
#
# The counts come from the exported SVG rather than from what the CLI reports it
# drew, and the two genuinely differ: the CLI counts *geometries* in the scene
# and the file contains *paths*, and `SVGExporter` writes one path per component,
# so a contour that clipping split in two arrives as two paths. 887 geometries
# are 889 paths in the current Santorini. The file is what Illustrator opens, so
# the file is what this counts.

set -euo pipefail

cd "$(dirname "$0")/.."

README="README.md"
CLI=".build/release/hipparchus-cli"

check_only=false
if [ "${1:-}" = "--check" ]; then
    check_only=true
elif [ -n "${1:-}" ]; then
    echo "usage: $0 [--check]" >&2
    exit 2
fi

test -x "$CLI" || {
    echo "error: $CLI is not built — run: swift build -c release" >&2
    exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Drawing Santorini…" >&2
OUTPUT="$("$CLI" santorini --out "$WORK" 2>&1)" || {
    echo "$OUTPUT" >&2
    echo "error: the render failed — the sources are online, so this needs network" >&2
    exit 1
}

SVG="$WORK/santorini.svg"
test -f "$SVG" || { echo "error: no SVG was written" >&2; exit 1; }

# Paths inside one layer's group. The groups do not nest, so a flag set at the
# group's own line and cleared at the next closing tag is enough.
paths_in() {
    awk -v layer="$1" '
        index($0, "data-layer-name=\"" layer "\"") > 0 { inside = 1; next }
        inside && /<\/g>/ { inside = 0 }
        inside && /<path/ { n++ }
        END { print n + 0 }
    ' "$SVG"
}

# Labels, not text elements: each is written twice, for its halo and its fill,
# at the same coordinates. Counting the elements says 34 where there are 17.
labels_in() {
    awk -v layer="$1" '
        index($0, "data-layer-name=\"" layer "\"") > 0 { inside = 1; next }
        inside && /<\/g>/ { inside = 0 }
        inside && /<text/ {
            match($0, /x="[^"]*" y="[^"]*"/)
            seen[substr($0, RSTART, RLENGTH)] = 1
        }
        END { print length(seen) }
    ' "$SVG"
}

contours="$(paths_in terrain_contours)"
index_contours="$(paths_in terrain_index_contours)"
bathymetry="$(paths_in bathymetry)"
summits="$(labels_in summits)"
longest="$(printf '%s\n' "$OUTPUT" | sed -n 's|.*longest contour: *\([0-9]*\) vertices.*|\1|p' | head -1)"

if [ -z "$longest" ]; then
    echo "error: the CLI did not report a longest contour" >&2
    exit 1
fi

stale=false
report() { printf '  %-16s %s\n' "$1" "$2"; }

update() {                                  # name, value
    local open="<!--santorini:$1-->" close="<!--/santorini:$1-->"
    grep -q "$open" "$README" || {
        echo "error: $README has no $open marker" >&2
        exit 1
    }
    # `|` as the delimiter and braces for perl: both markers contain a slash,
    # which ends an `s///` early.
    local stated
    stated="$(sed -n "s|.*$open\([0-9,]*\)$close.*|\1|p" "$README" | head -1)"
    local shown="$2"
    # The longest contour reads better with a thousands separator, as it always
    # has in this README. Grouped by hand rather than with printf's `%'d`, which
    # is locale-dependent and silently does nothing under LC_ALL=C.
    if [ "$1" = "longest" ]; then
        shown="$(printf '%s' "$2" | sed -e :a -e 's|\(.*[0-9]\)\([0-9]\{3\}\)|\1,\2|;ta')"
    fi
    if [ "$stated" = "$shown" ]; then
        report "$1" "$shown"
        return
    fi
    stale=true
    if [ "$check_only" = true ]; then
        report "$1" "${stated:-nothing} → should be $shown"
        return
    fi
    perl -pi -e "s{\Q$open\E[0-9,]*\Q$close\E}{$open$shown$close}g" "$README"
    report "$1" "${stated:-nothing} → $shown"
}

update contours "$contours"
update index "$index_contours"
update bathymetry "$bathymetry"
update summits "$summits"
update longest "$longest"

if [ "$check_only" = true ] && [ "$stale" = true ]; then
    echo "Run $0 to fix them." >&2
    exit 1
fi
