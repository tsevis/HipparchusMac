#!/bin/bash
#
# Keep the figures in README.md that come from a real render true.
#
#   Scripts/update-render-figures.sh           rewrite them
#   Scripts/update-render-figures.sh --check   say whether any are stale
#
# Two areas, because the README describes two: Santorini for what arrives in
# Illustrator, and the Myrtoan Sea for what the sea half of this does. Between
# them they were the last typed numbers in the README, and every one of them had
# drifted at least once — four of Santorini's five were wrong the first time this
# ran, and the Myrtoan figures drifted twice in one day.
#
# **This needs the network.** It draws both areas from real elevation and real
# coverage services, so it is not something to wire into a pre-commit hook. A
# warm cache makes it quick. `Scripts/update-test-count.sh` is the one that is
# safe to automate.
#
# Counts come from the exported SVG rather than from what the CLI reports it
# drew, because the two differ honestly: the CLI counts *geometries* in the scene
# and the file holds *paths*, and `SVGExporter` writes one path per component, so
# a contour that clipping split in two arrives as two paths. The file is what
# Illustrator opens, so the file is what this counts.
#
# The exceptions are stated where they are taken: a depth *band* is a band and
# not a path — its six bands are 139 paths, because a band is a multipolygon —
# and the deepest sounding is a number the CLI measures rather than a thing it
# draws.

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

stale=false

# --------------------------------------------------------------------------
# Reading the render
# --------------------------------------------------------------------------

# Paths inside one layer's group. The groups do not nest, so a flag set at the
# group's own line and cleared at the next closing tag is enough.
paths_in() {                                # svg, layer
    awk -v layer="$2" '
        index($0, "data-layer-name=\"" layer "\"") > 0 { inside = 1; next }
        inside && /<\/g>/ { inside = 0 }
        inside && /<path/ { n++ }
        END { print n + 0 }
    ' "$1"
}

# Labels, not text elements: each is written twice, for its halo and its fill,
# at the same coordinates. Counting the elements says 34 where there are 17.
labels_in() {                               # svg, layer
    awk -v layer="$2" '
        index($0, "data-layer-name=\"" layer "\"") > 0 { inside = 1; next }
        inside && /<\/g>/ { inside = 0 }
        inside && /<text/ {
            match($0, /x="[^"]*" y="[^"]*"/)
            seen[substr($0, RSTART, RLENGTH)] = 1
        }
        END { print length(seen) }
    ' "$1"
}

grouped() {                                 # 6658 -> 6,658
    printf '%s' "$1" | sed -e :a -e 's|\(.*[0-9]\)\([0-9]\{3\}\)|\1,\2|;ta'
}

# --------------------------------------------------------------------------
# Writing the README
# --------------------------------------------------------------------------

update() {                                  # marker name, value
    local open="<!--$1-->" close="<!--/$1-->"
    grep -q "$open" "$README" || {
        echo "error: $README has no $open marker" >&2
        exit 1
    }
    # `|` as the delimiter for sed and braces for perl: both markers contain a
    # slash, which ends an `s///` early in either.
    local stated
    stated="$(sed -n "s|.*$open\([0-9,]*\)$close.*|\1|p" "$README" | head -1)"

    if [ "$stated" = "$2" ]; then
        printf '  %-22s %s\n' "$1" "$2"
        return
    fi
    stale=true
    if [ "$check_only" = true ]; then
        printf '  %-22s %s → should be %s\n' "$1" "${stated:-nothing}" "$2"
        return
    fi
    perl -pi -e "s{\Q$open\E[0-9,]*\Q$close\E}{$open$2$close}g" "$README"
    printf '  %-22s %s → %s\n' "$1" "${stated:-nothing}" "$2"
}

# --------------------------------------------------------------------------
# Santorini — what arrives in Illustrator
# --------------------------------------------------------------------------

echo "Drawing Santorini…" >&2
OUT="$("$CLI" santorini --out "$WORK" 2>&1)" || {
    echo "$OUT" >&2
    echo "error: the render failed — the sources are online, so this needs network" >&2
    exit 1
}
SVG="$WORK/santorini.svg"
test -f "$SVG" || { echo "error: no Santorini SVG was written" >&2; exit 1; }

longest="$(printf '%s\n' "$OUT" | sed -n 's|.*longest contour: *\([0-9]*\) vertices.*|\1|p' | head -1)"
test -n "$longest" || { echo "error: the CLI reported no longest contour" >&2; exit 1; }

update santorini:contours   "$(paths_in "$SVG" terrain_contours)"
update santorini:index      "$(paths_in "$SVG" terrain_index_contours)"
update santorini:bathymetry "$(paths_in "$SVG" bathymetry)"
update santorini:summits    "$(labels_in "$SVG" summits)"
update santorini:longest    "$(grouped "$longest")"

# --------------------------------------------------------------------------
# The Myrtoan Sea — what the sea half does
# --------------------------------------------------------------------------
#
# The same frame, preset and palette as the plate in the README, on the same
# square sheet, so the figures describe the picture beside them.

echo "Drawing the Myrtoan Sea…" >&2
OUT="$("$CLI" --bbox 23.2,36.3,24.2,37.1 --preset "Coastal Survey" \
        --palette Admiralty --paper "Square" --dpi 72 --out "$WORK" 2>&1)" || {
    echo "$OUT" >&2
    echo "error: the Myrtoan render failed" >&2
    exit 1
}
SVG="$WORK/custom.svg"
test -f "$SVG" || { echo "error: no Myrtoan SVG was written" >&2; exit 1; }

# The deepest sounding, measured rather than drawn. Stated without its sign,
# because the prose around it already carries the minus.
depth="$(printf '%s\n' "$OUT" | sed -n 's|.*measured: *-\([0-9]*\) m to.*|\1|p' | head -1)"
test -n "$depth" || { echo "error: no measured depth in the Myrtoan render" >&2; exit 1; }

# A band is a band, not a path: the six of them are 139 paths, because a band is
# a multipolygon and the exporter writes one path per component.
bands="$(printf '%s\n' "$OUT" | sed -n 's|^ *depth_bands  *\([0-9]*\).*|\1|p' | head -1)"
test -n "$bands" || { echo "error: no depth band count in the Myrtoan render" >&2; exit 1; }

update myrtoan:depth    "$(grouped "$depth")"
update myrtoan:bands    "$bands"
update myrtoan:contours "$(paths_in "$SVG" bathymetry)"

if [ "$check_only" = true ] && [ "$stale" = true ]; then
    echo "Run $0 to fix them." >&2
    exit 1
fi
