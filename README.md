# HipparchusMac

A native macOS rewrite of [Hipparchus](../Hipparchus): choose an area of the
world, fetch map data from public sources, and export layered,
Illustrator-editable SVG.

The Python application is the specification. It is finished, it works, and its
454 tests are an executable description of the behaviour being ported. Anything
here that disagrees with it is a bug here.

**Status: the app is built.** Every online source, the composing source stack,
the sixteen presets, illuminated contours, the three-column interface and the
exports are in, with 328 tests and the output checked against real ground. See
`KICKOFF.md` for the brief.

Not built, and all understood rather than undecided: the file-backed providers
(`osmium`, `fiona`, `pyarrow`, PMTiles, MVT), which the brief calls the long
tail; the derived artistic layers a few presets ask for (Voronoi, Delaunay, hex
grid, circle packing), which currently render as empty layers rather than wrong
ones; and assembling OSM relations into multipolygons — see "Things that are not
bugs" below.

## Requirements

- macOS 15 or later
- Xcode 26 / Swift 6.2
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), to
  generate the app project
- CMake, **only** if you want to rebuild GEOS. The library is committed.

## Building

```sh
swift build                 # the libraries and the CLI
swift test -c release       # every test, about a second
swift test                  # the same tests, about thirty seconds
```

No test touches the network. Tiles are synthesised in-process, and the one real
tile in the suite is committed as a fixture.

**Run the suite in release.** Contouring is a tight numeric loop over a grid, and
Swift's unoptimised build runs it roughly fifty times slower — the whole
difference between the two numbers above. Debug is worth it only when you need a
debugger.

The app project is generated rather than committed, so `project.yml` is the
source of truth and there is no `.xcodeproj` to merge:

```sh
xcodegen generate --spec App/project.yml
open HipparchusMac.xcodeproj
```

## Layout

```
Sources/HipparchusGeometry   contours, Web Mercator, illumination, smoothing, orbits
Sources/HipparchusGEOS       the GEOS bridge, and the geometry that needs an engine
Sources/HipparchusData       the source stack, every provider, the cache, progress
Sources/HipparchusRender     presets, the scene builder, the canvas, SVG and PDF export
Sources/hipparchus-cli       headless fetch → render → export, for checking real output
App/                         project.yml and the SwiftUI views, which hold no logic
Vendor/geos                  the committed GEOS xcframework — see Docs/GEOS.md
```

The targets form a strict chain, `HipparchusGeometry ← HipparchusGEOS ←
HipparchusData ← HipparchusRender`. The Python had an import cycle between its
data layer and its application layer that no test caught, because every test
reached the application layer first. Separate targets make the same mistake a
compile error.

## Running it

The app opens on an empty canvas; pick an area, or a saved place, and press
Update map. It will also open straight onto an area, which is handy from a
terminal or a script:

```sh
Hipparchus.app/Contents/MacOS/Hipparchus --bbox 25.32,36.33,25.50,36.48
```

The CLI does the same thing headlessly and writes PNG, SVG, PDF and a
diagnostics JSON:

```sh
swift run -c release hipparchus-cli santorini
swift run -c release hipparchus-cli --all --out out
swift run -c release hipparchus-cli --bbox 23.2,36.3,24.2,37.1
```

Build it in release. In debug the contour tracer is about thirty times slower,
which is the difference between a six-second fetch and a three-minute one.

## Verifying output

Rendering is visual, so the checks are numbers rather than impressions. These
areas have known answers, and the CLI prints what it measured next to what was
expected. Every one currently matches:

| Area | Bounding box | Expected | Measured |
|---|---|---|---|
| Santorini | `25.32, 36.33 → 25.50, 36.48` | −79 m floor, 525 m rim | −79 m to 525 m |
| Athens | `23.575, 37.816 → 23.895, 38.136` | −4 m to 1091 m | −4 m to 1091 m |
| San Francisco | `−122.53, 37.70 → −122.35, 37.84` | tops at 284 m | −114 m to 284 m |
| Addis Ababa | `38.65, 8.90 → 38.88, 9.10` | never below 2,075 m | 2075 m to 3127 m |
| Everest | `86.85, 27.93 → 87.05, 28.06` | 5,060 m to 8,746 m | 5060 m to 8746 m |
| Myrtoan Sea | `23.2, 36.3 → 24.2, 37.1` | −1,310 m, ~546 sub-sea contours | −1310 m, 546 |

Athens, Addis Ababa and Everest yield no bathymetry; the Myrtoan Sea yields five
summits rather than two dozen. Santorini's Illustrator layers come out as 178
contours, 798 index contours, 7 bathymetry and 24 summit labels — the same counts
the Python's own screenshot shows — and its longest contour is 8,097 vertices,
arriving whole.

Beyond that, three fixtures compare this port against the Python directly rather
than against my reading of it:

- **Contours** — the same field traced by both, matching line for line and vertex
  for vertex across five levels, 24 lines and 644 vertices.
- **Elevation bands** — areas matching Shapely to one part in 10⁹, and polygon and
  hole counts matching exactly, over a cone and a crater.
- **Terrarium decoding** — a real AWS tile decoded to the same metres by Core
  Graphics, skia and PIL.

Regenerate them with the scripts in `Scripts/`. A diff there means one of the two
implementations changed; find out which before accepting it.

## Verifying the app itself

Rendering is visual and a window cannot be asserted on, so the app will drive its
own model headlessly and write the result:

```bash
Hipparchus.app/Contents/MacOS/Hipparchus --bbox 23.575,37.816,23.895,38.136 --sources terrain_tiles --preset "Contour Study" --render-to athens.png
```

It prints what it measured and writes the PNG into the app's container
(`~/Library/Containers/com.hipparchus.HipparchusMac/Data/Documents`), because the
app is sandboxed and may only write where it has been pointed. With no arguments
it opens on the session it last saved.

This exercises the path the window uses — the source stack, the manager, the
scene builder and the renderer. It does **not** check the SwiftUI layout; only a
person looking at the window can do that.

Santorini through OpenStreetMap alone comes out as 14 layers and 10 772
features; ticking Elevation on top gives 19 layers, 11 787 features and −79 m to
525 m. The streets are still there. That is the whole idea of the source stack,
and it is why the check is worth running.

## Things that are not bugs

- **OSM relations are not assembled into multipolygons.** Overpass is asked for
  `out body geom`, and each way comes back as its own geometry, so a large water
  or coastline *relation* draws as its member ways rather than as one filled
  shape — most visibly as a wedge of sea off a coast. The Python does the same
  thing. Fixing it means assembling outer and inner rings from relation members
  before anything else touches them.
- **Faint straight diagonals** in elevation output are void-fill seams and
  dataset boundaries in the source mosaic. They are in the raw grid before any
  contouring. Removing them properly would mean blurring real terrain.
- **In cities the highest ground is a building.** The elevation mosaic is a
  surface model, not bare earth.
- **Cancel cannot abort a request already in flight.** It skips sources that have
  not started, stops those that check between requests, and discards the result
  rather than drawing it. An HTTP request already sent runs to completion.

## Provenance

Every source declares what it is — `measured`, `synthetic`, `uncalibrated` or
`approximate` — on its features, on the merged metadata, on the scene and in the
exported diagnostics. This is what stops a generated map being mistaken for a
survey. It is a guarantee, not decoration; a new source needs the same.

## Licence

The application is MIT, as the Python is. GEOS is LGPL-2.1 and is statically
linked; see `Vendor/geos/MANIFEST.txt` and `Docs/GEOS.md`.
