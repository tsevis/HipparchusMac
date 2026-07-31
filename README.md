# HipparchusMac

A native macOS rewrite of [Hipparchus](https://github.com/tsevis/Hipparchus):
choose an area of the world, fetch map data from public sources, and export
layered, Illustrator-editable SVG.

<table>
  <tr>
    <td width="50%"><img src="Docs/assets/gallery-hawaii-hypsometric.png" width="100%" alt="The island of Hawaii as filled elevation bands, Mauna Kea and Mauna Loa reading as concentric shields, from real elevation data"></td>
    <td width="50%"><img src="Docs/assets/gallery-amsterdam-fragmented-urban.png" width="100%" alt="Amsterdam's canals, rail fan and building footprints drawn from OpenStreetMap"></td>
  </tr>
</table>

The Python application is the specification. It is finished, it works, and its
454 tests are an executable description of the behaviour being ported. Anything
here that disagrees with it is a bug here.

**Status: the app is built, and the window has never been looked at.** Every
online source, the composing source stack, the sixteen presets, illuminated
contours, the three-column interface and the exports are in, with 606 tests and
the output checked against real ground. See `KICKOFF.md` for the brief.

Every claim here is backed by a test or by a render someone can open. **None of
them is a claim about the interface**, because this environment has no Screen
Recording permission and no window of any application can be captured. The model
behind the window is verified; the layout is not, and "Verifying the app itself"
below is as close as anything headless gets.

What this port deliberately does not have is listed under "What is not here",
which distinguishes decided-against from overlooked.

## Requirements

- macOS 15 or later
- Xcode 26 / Swift 6.2
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), to
  generate the app project
- CMake, **only** if you want to rebuild GEOS. The library is committed.

## Building

```sh
swift build                 # the libraries and the CLI
swift test -c release       # every test, about two seconds
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
open App/HipparchusMac.xcodeproj
```

To get a double-clickable app rather than an Xcode session, one script builds it
in release and puts it in `/Applications`:

```sh
Scripts/install-app.sh
```

And for a disk image, named for the version and the commit it came from:

```sh
Scripts/make-dmg.sh          # → dist/Hipparchus-0.1.0-<sha>.dmg
```

The signature is **ad-hoc**, and that matters more for the image than for the
app. It is enough to run on the machine that built it. It is not enough to hand
to anyone else: a downloaded image carries a quarantine flag, and with no
Developer ID and no notarisation behind it macOS refuses to open the app at all
until the reader right-clicks it and chooses Open, or clears the flag by hand.

That is a reasonable thing to ask of yourself and an unreasonable thing to ask
of anyone else. Real distribution needs an Apple Developer account, a Developer
ID certificate and `notarytool`; this builds something that looks distributable
and is not, so it says so rather than letting the disk image imply otherwise.

## Layout

```
Sources/HipparchusGeometry   contours, Web Mercator, illumination, smoothing, orbits
Sources/HipparchusGEOS       the GEOS bridge, and the geometry that needs an engine
Sources/HipparchusData       the source stack, every provider, the cache, progress
Sources/HipparchusRender     presets, the scene builder, the canvas, SVG and PDF export
Sources/hipparchus-cli       headless fetch → render → export, for checking real output
App/                         project.yml, the SwiftUI views, and MapModel
Vendor/geos                  the committed GEOS xcframework — see Docs/GEOS.md
```

The targets form a strict chain, `HipparchusGeometry ← HipparchusGEOS ←
HipparchusData ← HipparchusRender`. The Python had an import cycle between its
data layer and its application layer that no test caught, because every test
reached the application layer first. Separate targets make the same mistake a
compile error.

**`App/` is the one target with no tests**, so what lives there is kept to
wiring. The rules a change has to obey are values in the package, where they can
be checked: `SessionHistory` decides what undo restores and when a run of edits
is one action, and `SessionEdit` decides what the Edit menu calls it — naming
that once lived in the window as three observers diffing model properties, where
no rule could be checked without a person opening the menu and reading it. Every
property observer now does the same thing: take a `Session`, hand it to those
two, act on the answer.

That leaves `MapModel` holding the parts that genuinely need the window — which
provider a ticked source builds, what the status bar says, when to warn before
an expensive fetch. It is still the layer this project has least evidence about.
Logic that grows here should move down rather than settle.

## Running it

The app opens on an empty canvas. Type a place into the search box — "Santorini",
"Twin Peaks San Francisco" — pick from what comes back, and press Update map. The
results show the frame each one would give before you commit to it, and the
coordinate boxes are still there, one disclosure away, for saying exactly which
frame you want.

Searching queries two geocoders and merges what they answer, still with no key
and no account. MapKit is good at landmarks and addresses and unreliable at
named geographic areas: asked for "Lesvos" it can answer with a taverna in
Athens called "Ouzeri Lesvos" and never mention the island. Nominatim —
OpenStreetMap's own geocoder, the same data the map layers already come from —
indexes real boundary polygons, so it answers both "Lesvos" and "Limnos"
correctly and unambiguously where MapKit alone conflated them with same-named
decoys. A real boundary reads first; MapKit's results, better at the specific
address or landmark Nominatim would miss, follow. Nominatim asks in return for
at most one request a second, which `NominatimGeocoder` holds to for the same
reason `OverpassProvider` already does.

MapKit still supplies the placemark's own extent where it has one, and the
extent of the whole response where it does not — the difference between
framing Everest and framing a 141-metre patch of rock, that being what MapKit
answers for the mountain itself. It will also open straight onto an area, which
is handy from a terminal or a script:

```sh
Hipparchus.app/Contents/MacOS/Hipparchus --bbox 25.32,36.33,25.50,36.48
Hipparchus.app/Contents/MacOS/Hipparchus --search "Twin Peaks San Francisco"
```

**Paste Coordinates**, beside the coordinate boxes, reads whatever is on the
clipboard rather than asking for four numbers typed one at a time. It reads a
box copied from this app's own `--bbox` output (`west, south, east, north`),
two corners copied from elsewhere, a bare point — latitude first, the
convention Google Maps, Apple Maps and every GPS device already copy in — or a
Google or Apple Maps link with the coordinates in its address. Four numbers
that are ambiguous between this app's own convention and two lat,lon corners
resolve to this app's convention, since that is what four bare numbers already
mean everywhere else here.

```sh
Hipparchus.app/Contents/MacOS/Hipparchus --import-clipboard
```

exists for the same reason `--search` does: a button is not something a
screenshot-less environment can click, so this drives the real
clipboard-reading code and prints what it found.

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

## Gallery

Ten regions, drawn by this app, each in a different preset. They are also the
widest test it has been put through: every one was fetched, built and rendered
in a single run, and the elevations below were read off the result rather than
asserted in advance.

**Terrain, from the elevation mosaic alone.** No account, no key, global.

<table>
  <tr>
    <td width="50%"><img src="Docs/assets/gallery-papua-new-guinea-contour-study.png" width="100%" alt="Papua New Guinea in illuminated contours, the Owen Stanley Range and the trenches around New Britain"></td>
    <td width="50%"><img src="Docs/assets/gallery-france-hypsometric.png" width="100%" alt="France as filled elevation bands, the Alps and Pyrenees against the Atlantic shelf"></td>
  </tr>
  <tr>
    <td width="50%"><img src="Docs/assets/gallery-ghana-relief-sheet.png" width="100%" alt="Ghana as a dense hairline relief sheet, the Volta basin and the Akwapim ridge"></td>
    <td width="50%"><img src="Docs/assets/gallery-hawaii-hypsometric.png" width="100%" alt="The island of Hawaii as filled elevation bands, five shield volcanoes and the sea floor around them"></td>
  </tr>
</table>

**Cities, from OpenStreetMap**, two of them with elevation stacked underneath —
which is the whole point of the source stack: ticking Elevation onto a street
map adds contours and never discards the streets.

<table>
  <tr>
    <td width="50%"><img src="Docs/assets/gallery-amsterdam-fragmented-urban.png" width="100%" alt="Amsterdam in the Fragmented Urban preset, canals, the IJ and the Centraal rail fan"></td>
    <td width="50%"><img src="Docs/assets/gallery-dusseldorf-clean-atlas.png" width="100%" alt="Dusseldorf in the Clean Atlas preset, the Rhine and the Altstadt"></td>
  </tr>
  <tr>
    <td width="50%"><img src="Docs/assets/gallery-los-angeles-technical-blueprint.png" width="100%" alt="Los Angeles in the Technical Blueprint preset, the downtown grid with contours beneath it"></td>
    <td width="50%"><img src="Docs/assets/gallery-toronto-editorial-print.png" width="100%" alt="Toronto in the Editorial Print preset, the waterfront and the downtown core"></td>
  </tr>
  <tr>
    <td width="50%"><img src="Docs/assets/gallery-rio-night.png" width="100%" alt="Rio de Janeiro in the Night preset, lit streets over the Tijuca massif with Copacabana and Ipanema"></td>
    <td width="50%"><img src="Docs/assets/gallery-beijing-figure-ground.png" width="100%" alt="Beijing in the Monochrome Figure Ground preset, the hutong blocks against the ring roads"></td>
  </tr>
</table>

The elevations are worth stating, because they are the check: nothing here was
chosen to flatter the renderer, and each number can be looked up.

| Region | Measured | What it should be |
|---|---|---|
| Papua New Guinea | −8 836 m to 4 084 m | the New Britain Trench bottoms at −8 940 m |
| Hawaii | −5 594 m to 4 177 m | Mauna Kea is 4 207 m |
| France | −5 022 m to 4 222 m | the Alps, sampled at zoom 7 |
| Ghana | −3 937 m to 916 m | Mount Afadja is 885 m |
| Rio de Janeiro | −529 m to 778 m | the Tijuca massif |
| Los Angeles | 49 m to 245 m | downtown to the Hollywood Hills |

The city sheets have their label layers switched off, the same switch the Layers
panel offers. With them on, four label layers thin independently and a dense
city carries several hundred names — true to the data and busier than a sheet
wants to be.

**That run found a bug**, which is what a wide test is for: on Hawaii every
summit label sat on top of its neighbour. See "What is not here" for the reason
and the fix.

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

## Turning the view

The map turns fifteen degrees a step from the controls on the canvas, which is
what it takes to run a coastline horizontally or square a street grid to the
page. The readout doubles as the way back to north, and Fit undoes the turn
along with the zoom.

Rotation is **view state, not map state**: like pan and zoom it is absent from
the session and from the undo history, and the exporters build their transform
with a fresh viewport — so turning the preview frames the screen, never the
file. The Python behaves the same way.

Fixing this exposed an older defect. Zoom and rotation both happened about the
origin of the pre-transform space rather than the middle of the canvas, so a map
at zoom 3 landed three times its own offset down and right, and a map at 90°
left the window altogether. The round-trip test passed throughout — an inverse
can be exact and still describe the wrong picture — so the test that catches it
now asserts where the content *lands*, and a second one counts painted pixels
in a turned render.

To look at a turned sheet without a window:

```bash
Hipparchus.app/Contents/MacOS/Hipparchus --bbox 25.32,36.33,25.50,36.48 --rotate 30 --render-to turned.png
```

**One deliberate exception.** Pan and zoom stay out of the requested area right
up until the moment **Update map** is pressed — that button is asking the app
to act on what is actually on screen, so it reads the canvas's current pan,
zoom and rotation, sets the area to whatever ground that implies, and resets
the view to a plain fit before fetching. Without this, zooming out and pressing
Update map re-fetched the same area as before while the screen still showed the
wider view, and looked exactly like nothing had happened. `CanvasTransform` does
the measuring — reading all four corners of the canvas rather than two opposite
ones, since a turned viewport's visible ground is a turned rectangle and only
the full corner set gives its true bounds — and it is tested there.

The button itself is a few lines of wiring this environment cannot watch
someone click, so it is verified a different way: `--verify-zoom-then-update`
builds the real `MapCanvasView`, pushes it through a real `draw(_:)` into an
offscreen bitmap context so its transform is the one the window would build,
then calls the exact `visibleArea()` and `syncAreaToVisibleView` the button
does, against a live fetch.

```bash
Hipparchus.app/Contents/MacOS/Hipparchus --bbox 25.32,36.33,25.50,36.48 --sources simulated_terrain --verify-zoom-then-update 0.5
```

```
requested area:           25.3200,36.3300 -> 25.5000,36.4800  (0.180° × 0.150°)  ·  14355 geometries
on screen at zoom 1:      25.2688,36.3198 -> 25.5512,36.4902  (0.282° × 0.170°)
on screen at zoom 0.5:    25.1276,36.2344 -> 25.6924,36.5753  (0.565° × 0.341°)
extent ratio vs. zoom 1: 2.000× lon, 2.000× lat  (expected 2.000×)
after re-fetch:           25.1276,36.2344 -> 25.6924,36.5753  (0.565° × 0.341°)  ·  16212 geometries
```

The first version of this check compared the zoomed-out view against the
*requested* bbox and got 3.14× instead of 2×. That was a bug in the check, not
the feature: the requested bbox and what is actually on screen at zoom 1
already differ, by the fit margin and by whatever the content's own aspect
ratio letterboxes against the canvas's — comparing against the wrong baseline
blamed this feature for an effect that had nothing to do with it. Against the
right baseline — what zoom 1 actually shows — the ratio lands exactly on 2.000×
in both directions, and the same check at zoom 2.0 and zoom 0.2 lands exactly
on 0.500× and 5.000×.

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

## Page furniture

The SVG export can carry a title block, a scale bar, a north arrow and a simple
legend, composed for a paper preset — A4 and A3 at 300 dpi, a square, a poster —
with the orientation turning the sheet rather than the map. Ported from
`export/profiles.py` and the furniture half of `export/svg_clean.py`, and like
the Python it is **all off by default**: the map is the product, and furniture
is asked for per export from the Page section of the style column, not
remembered as map state.

The scale bar is drawn a round number of pixels long and *labelled* with the
ground distance it happens to span — the label is derived from the transform,
so it cannot lie — in the projection's own units, kilometres or degrees. On a
dark preset the furniture inverts, or it would vanish into the ground. The
legend names layers what the layer panel names them; the Python keeps a second
label map in `svg_clean.py` that differs from its own panel in casing, and
carrying that fork over would have been porting a bug.

Headlessly, `hipparchus-cli santorini --furniture` writes the full sheet for
looking at.

## The sea, which OSM does not give you

OpenStreetMap describes a coast as open ways, not as a filled ocean, so a coastal
sheet drawn from the linework alone has a line where the water should be. The
frame's own boundary and the coastline together cut the page into faces, and the
face carrying the least evidence of land — a building counts for more than a
road, since a road may bridge water but a building does not float on it — is the
sea.

Measured, never assumed: the same principle as elevation bands, which sample the
field at each face rather than reasoning about which ring contains which. It
returns nothing when it cannot tell — no coastline, a coast that does not divide
the frame, or every face scoring alike — because a line where the sea should be
is a smaller error than the sea painted over the town. The count is in the
scene's diagnostics as `inferred_sea_polygons`, since a reader is entitled to
know the water was reasoned rather than measured.

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

## What is not here

The Python is the specification, and a port that quietly drops things is worse
than one that says which. Everything below exists there and not here **on
purpose**; anything not listed is either ported or a bug. This list was
assembled by auditing the Python module by module, because until that audit
three layers were styled by every preset and populated by nothing, and nobody
had noticed.

**Whole features, not ported.**

- **Saved presets.** `application/preset_store.py` lets a user name and keep
  their own preset. Here `Session` stores the name of a built-in and nothing
  else. The sixteen are a designed set; a seventeenth is a different feature —
  a preset editor — and half of it (a save button with no way to edit what it
  saves) would be worse than none.
- **A settings store.** `core/settings_store.py` and the Settings tab it feeds:
  theme, label font family and size, device scale, cache size limit, preview
  tolerance. The two knobs from it that actually change a fetch — Overpass
  timeout and rate — are inline settings on the OpenStreetMap source instead,
  where the rest of a source's settings live. The remainder are appearance
  preferences that macOS mostly answers already.
- **Plugins.** `plugins/loader.py` and `plugins/interfaces.py` load extra
  providers from `~/.hipparchus/plugins` at start-up. A Swift equivalent means
  either dynamic loading into a sandboxed, signed app or an XPC service; both
  are real projects, and neither is cartography.
- **The AOI cache index.** `cache/index.py` keeps an `index.json` of endpoint,
  area hash, layer-set hash and schema version beside the cache. Here the cache
  key is a hash of the same things, so a changed query simply misses. What the
  index buys that hashing does not is a cache a person can read and a size cap
  to enforce; the size cap is the part worth adding first.
- **An in-app diagnostics panel.** The Python's "Explain This Map" shows the
  CRS, the quality profile and the invalid-geometry count in a window. The same
  numbers are written beside every export as `<file>.diagnostics.json`, and the
  status bar carries the summary — but nothing in the window explains itself
  the way that panel does.
- **Reading GeoParquet directly.** See "File sources" for the reason and for the
  one `duckdb` command that gets past it.

**Smaller divergences, each deliberate.**

- **`supersample` is gone, because it made the maps worse.** The Python's
  quality profiles oversample the preview bitmap — skia rasterised it, and 1.5×
  averaged down was an improvement there. Ported here it was declared and read
  by nothing, so it was implemented properly and then measured on a Santorini
  sheet with everything but the sampling held still:

  | Oversampling | Local contrast | Ink |
  |---|---|---|
  | 1× | 2.77 | 33.03 |
  | 1.5× | 2.21 | 31.96 |
  | 2× | 1.74 | 31.11 |

  Both fall monotonically. Contours on these sheets sit a pixel or two apart, so
  averaging merges neighbouring lines into a smear and lightens every hairline,
  and the type softens with them. Core Graphics antialiases against the real
  pixel grid and keeps each line's contrast, which is what line art needs. The
  field, its four values and the wiring are deleted rather than left as a knob
  that costs 2.25× the pixels to make a map harder to read.

  **A synthetic measurement said the opposite**, and is worth recording as a
  warning: scoring each candidate against a 4× downsample as though that were
  ground truth showed a 38% improvement, because the reference *is* the smear —
  it rewarded exactly the blurring it should have caught. Looking at two crops
  side by side settled it in seconds. A metric that encodes the wrong ideal is
  more dangerous than no metric.
- **Label collision boxes are a fraction of the frame, not 50 metres.** The
  Python reserves a fixed box around each label — 50 units wide, 20 tall — in
  projected space, and its own docstring calls that "obvious projected-space
  overlap". Those units are metres. Across a city that is a few pixels; across
  an island chain 150 km wide it is a fraction of one, so no two boxes can ever
  overlap and the thinning does nothing at all. A render of Hawaii put every
  summit height on top of its neighbour. Sized against the frame instead, it
  means the same thing at every scale.
- **Simplification does not collapse collinear runs.** `simplification.py` walks
  the vertex list removing redundant nodes; here GEOS `simplify` does the work
  and nothing counts removed nodes afterwards.
- **An unstyled layer draws as a hairline, not as a filled grey shape.** The
  Python falls back to a default `LayerStyle` — a 1.0 dark stroke *with* a grey
  fill enabled — so an unstyled polygon layer arrives filled. Here the fallback
  is a 0.5 grey hairline with fill off, which shows that a new layer exists
  without asserting a colour for it.
- **The SVG has no per-path `id`.** Groups are named and carry
  `data-layer-name`, which is what Illustrator reads; numbering every path
  inflates the file for nothing.
- **Launch configuration is flags, not environment variables.** `core/config.py`
  reads start area, preset, sources, and the cache, plugin and preset
  directories from the environment. The first three are command-line flags here;
  the last three belong to features that are not ported.

**Where this port goes further than the Python**, also on purpose: the road
hierarchy caps each class separately, `ferry_routes` is its own layer, the
Delaunay derivation and the derived-layer boundary both read the road hierarchy
rather than a layer classification has already deleted, footprints are divided
at the date line, `night_lights` and `admin_boundaries` have places in the draw
order, and PDF and PNG export are real rather than stubs.

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
