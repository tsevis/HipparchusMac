# HipparchusMac

A native macOS rewrite of [Hipparchus](../Hipparchus): choose an area of the
world, fetch map data from public sources, and export layered,
Illustrator-editable SVG.

The Python application is the specification. It is finished, it works, and its
454 tests are an executable description of the behaviour being ported. Anything
here that disagrees with it is a bug here.

**Status: the app is built.** Every online source, the composing source stack,
the sixteen presets, illuminated contours, the three-column interface and the
exports are in, with 454 tests and the output checked against real ground. See
`KICKOFF.md` for the brief.

Not built, and understood rather than undecided: reading GeoParquet directly —
see "File sources" below for why, and for the one command that gets past it.

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

The app opens on an empty canvas. Type a place into the search box — "Santorini",
"Twin Peaks San Francisco" — pick from what comes back, and press Update map. The
results show the frame each one would give before you commit to it, and the
coordinate boxes are still there, one disclosure away, for saying exactly which
frame you want.

Searching uses MapKit, so there is no key and no account. It reports a
placemark's own extent where there is one, and the extent of the whole response
where there is not — which is the difference between framing Everest and framing
a 141-metre patch of rock, that being what MapKit answers for the mountain
itself. It will also open straight onto an area, which is handy from a
terminal or a script:

```sh
Hipparchus.app/Contents/MacOS/Hipparchus --bbox 25.32,36.33,25.50,36.48
Hipparchus.app/Contents/MacOS/Hipparchus --search "Twin Peaks San Francisco"
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

## Undo

Everything a person can do is undoable — the area, however it was set; ticking a
source and every inline setting; the preset and the quality; hiding a layer; the
derived-layer switches and their sizes; and fetching a map. ⌘Z and the Edit menu
name the action they will take back: "Undo Choose Place", "Undo Change Preset",
"Undo Fetch Map".

Two rules carry the design. A stepper drag or a typed coordinate coalesces into
one action, because it was one intention. And **undo of a fetch restores the
previous scene from a bounded store rather than re-fetching** — undo must never
cost minutes of Overpass time to take back something that cost minutes of
Overpass time. Only the newest few scenes are kept, so undoing very far back can
reach a map that was let go; the status bar says so, and Update map redraws it —
nothing ever re-fetches silently.

The history itself is `SessionHistory`, a value type over `Session` snapshots,
and every rule above is a test that runs without a window. The window's own
`UndoManager` is driven by it, one registration per boundary, so the keyboard
and the menu belong to the system.

## Street names

One label per named street, on its longest run. OSM splits a street into a way
per block, so labelling every feature would stamp the same name dozens of times
down one road; keeping the longest run per name puts the label where the street
is most legible. Ported from `_street_labels`, budgeted at 90 labels a sheet,
and checked against a fetch of central Athens.

## Things that are not bugs

- **A ferry route crosses open water in a straight line**, because it does. OSM
  tags the Piraeus–Serifos service `route=ferry` and `waterway=seaway`, and it
  runs 80 km from the Saronic Gulf out to Serifos in eighty vertices. It is drawn
  in its own `ferry_routes` layer, so it can be turned off in the layer panel if
  a sheet does not want shipping on it.
- **Faint straight diagonals** in elevation output are void-fill seams and
  dataset boundaries in the source mosaic. They are in the raw grid before any
  contouring. Removing them properly would mean blurring real terrain.
- **In cities the highest ground is a building.** The elevation mosaic is a
  surface model, not bare earth.
- **Cancel cannot abort a request already in flight.** It skips sources that have
  not started, stops those that check between requests, and discards the result
  rather than drawing it. An HTTP request already sent runs to completion.

## Relations, and why they need assembling

An OSM multipolygon is a **relation**: a list of member ways, in arbitrary order
and arbitrary direction, with each member marked `outer` or `inner`. `out geom`
resolves each member's vertices but joins none of them up, so until the
fragments are stitched there is no ring, and until there is a ring there is no
area to fill. Relations used to be dropped outright — 1 097 of them in an Athens
fetch, mostly buildings with courtyards.

`RingAssembly` stitches fragments end to end through a map from endpoint to
fragment, reversing any that join the wrong way round, and puts each hole inside
the *smallest* outer ring containing it — rings nest, and an island in a lake in
an island must not hand its lake to the outermost coastline. It is linear in
total vertices rather than quadratic in fragments, which matters: the Aegean Sea
relation in an Athens fetch is 2 055 outer ways and 1 768 inner ones, and it
assembles into one ring of 237 145 vertices carrying 333 islands as holes.

Two ways joined in OSM share a *node*, so their endpoints are equal to the last
bit and the assembly compares them exactly. A tolerance would risk joining ways
that merely pass close.

A relation that never closes keeps its edges as lines rather than vanishing, and
never claims to be an area.

## File sources

Four sources read a file rather than the network, and one provider serves all of
them, dispatching on what the file turns out to be. That is how the Python does
it, and the reason is **GeoJSON**: every file-backed source accepts it, so a
format this app cannot read natively is still reachable by converting it once.

The Python reaches for `osmium`, `fiona`, `pyarrow`, `mapbox_vector_tile` and
`pmtiles`, and reports a missing one as an unavailable source. Swift has none of
those, so the readers are written here:

| Format | Source | Read by |
|---|---|---|
| GeoJSON, GeoJSONL, or a folder of either | all four | `GeoJSONReader` |
| Shapefile (`.shp` + `.dbf`) | Natural Earth | `ShapefileReader` |
| MBTiles, PMTiles → Mapbox Vector Tiles | Vector tiles | `VectorTileReader`, `MVT` |
| OSM PBF extract | Local OSM extract | `OSMPBFReader` |
| GeoParquet | Overture | not directly — see below |

Each is written to its published layout, and each test builds a real file byte by
byte rather than checking a recorded blob, so a failure points at the reader
rather than at something nobody can inspect.

Three details cost the most to get right, and all three are silent when wrong:

- **MBTiles rows are TMS**, counting from the *south*, where every other tile
  scheme here counts from the north. Reading a row unflipped finds a tile from
  the wrong hemisphere.
- **A vector tile is a command stream**, not a list of points, and its deltas
  accumulate across commands rather than resetting per ring.
- **OSM PBF needs two passes.** Ways reference nodes by id, so a way cannot be
  drawn until its nodes are known, and holding a continent in memory to avoid
  the second pass is not a trade worth making.

**GeoParquet is not read directly**, and the obstacle is compression rather than
structure. Overture writes ZSTD, Parquet commonly writes Snappy, and macOS ships
neither — Apple's Compression framework offers Brotli, LZ4, LZFSE and LZMA, none
of which Parquet uses. Reading it here would mean writing a ZSTD decoder from
scratch, with no real archive to check it against, for one source that converts
in one command:

```bash
duckdb -c "COPY (SELECT * FROM 'in.parquet') TO 'out.geojson' WITH (FORMAT GDAL, DRIVER 'GeoJSON')"
```

The app says exactly that when handed one, rather than returning an empty map.

## The one source that needs nothing

`Simulated terrain` generates its own relief instead of reading anyone's, so
contour work is reachable on a bare install with no file, no account and no
network — and so the rest of the pipeline can be exercised offline.

The field is **anchored to geography rather than to the window**: the landform
size depends only on how wide the window is, never on where it is, so panning at
one zoom walks across one continuous landscape instead of re-rolling a new one
each time. That is the difference between a map and wallpaper, and there is a
test that reads the same ground from two overlapping windows and requires the
same height back.

The elevations are **invented**, and everything it emits says so — on the
features, in the merged metadata, and on the scene. A stack holding it can only
claim `synthetic`, because the weakest claim any source makes is the claim the
merged map is entitled to.

Its parity fixture checks more than the others: the integer lattice hash bit for
bit, then value noise, then the fractal sum, then the window-to-landform ladder,
then full elevation grids for four real windows. Each layer separately, so a
failure points at the step that moved rather than at the end of a long chain —
and because a wrong shift in the hash produces a perfectly good landscape that is
simply not the one the seed names. Two details it pins down: a negative
coordinate has to become the same very large unsigned integer in both languages,
and a window landing exactly half-way between two rungs of the ladder has to
round to even, as Python's `round` does and Swift's default does not.

## Derived layers

Four layers are **invented from the map rather than fetched with it**: Voronoi
cells around the buildings, a Delaunay mesh between road junctions, a hex grid,
and packed circles. Each is clipped to the convex hull of what the map actually
holds — a union of every building, road and park is full of holes and inlets, and
a grid clipped to *that* would be lace.

Voronoi and Delaunay come from GEOS, which the brief settled: `GEOSVoronoiDiagram`
and `GEOSDelaunayTriangulation` replace the SciPy usage, and with them go two
hundred lines of the Python — a hand-rolled reconstruction of finite Voronoi
polygons from Qhull's infinite ridges, a fallback for when SciPy will not import
against the local NumPy ABI, and a second fallback that draws squares around each
site and calls them cells.

**No preset turns any of them on.** All sixteen style the four layers and three
tune the hex radius and circle sizes, but every switch is off — in this port and
in the Python, where nothing outside a test ever sets one. So they are switched
from the Derived section of the style column, or on launch:

```bash
Hipparchus.app/Contents/MacOS/Hipparchus --bbox 25.40,36.39,25.46,36.44 --derive voronoi,hex
```

Everything they produce is **synthetic**: a pattern read out of the data, not a
measurement of anything, and the panel says so.

Two costs are bounded rather than left to grow. Road junctions are found through
a grid index rather than by comparing every line with every other, and capped at
three thousand seeds. Circle packing walks a lattice that is quadratic in the
area while its step is fixed by the smallest circle, so the lattice is capped and
the step widens to fit: a 5 km frame at an 8 m step took seven seconds before
that, and thirty kilometres would have taken four minutes.

## Roads are eight layers

Every one of the sixteen presets styles a road hierarchy — a motorway at five
units in blue, a primary at four in red, a residential at two in white, a service
road at one and a half in grey — and the eight layers are named in the draw order
and labelled in the panel. Until the classifier ran, none of it was used: every
road landed in the generic `roads` layer and drew at one weight, so a footpath
looked exactly like a motorway. An Athens fetch is 111 208 roads.

The split happens before anything else touches them, so the rest of the pipeline
sees the layers the presets are written for. One departure from the Python, which
caps the *total* across the classes while classifying: here each class meets the
per-layer cap on its own, which is how every other layer is already treated, and
means a motorway is never dropped because forty thousand footpaths came first.

## Where OSM tags land

Layers are a reading of OSM tags, and the reading is ported from the Python. One
place it deliberately differs: **routes are not water.** OSM tags the
Piraeus–Serifos ferry `waterway=seaway`, so a rule keyed on the presence of a
`waterway` tag drew an 80-kilometre crossing of the Saronic Gulf as if it were a
river. `route=ferry`, `waterway=seaway` and `waterway=fairway` now land in
`ferry_routes`, which is asked for in its own right — a route tagged only
`route=ferry` has no `waterway` at all and the water query would never have
returned it.

The split is narrow on purpose. An Athens fetch holds 852 streams, 121 canals,
54 rivers, 43 ditches and 39 drains, and every one of them is still water.

No preset styles `ferry_routes`, so it draws as the fallback hairline. That is
the designed behaviour for a layer a preset says nothing about, and it is why a
new layer shows up as *something* the first time it appears rather than silently
not rendering.

## Provenance

Every source declares what it is — `measured`, `synthetic`, `uncalibrated` or
`approximate` — on its features, on the merged metadata, on the scene and in the
exported diagnostics. This is what stops a generated map being mistaken for a
survey. It is a guarantee, not decoration; a new source needs the same.

## Licence

The application is MIT, as the Python is. GEOS is LGPL-2.1 and is statically
linked; see `Vendor/geos/MANIFEST.txt` and `Docs/GEOS.md`.
