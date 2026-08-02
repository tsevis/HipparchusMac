# HipparchusMac

A native macOS rewrite of [Hipparchus](https://github.com/tsevis/Hipparchus):
choose an area of the world, fetch map data from public sources, and export
layered, Illustrator-editable SVG.

<img src="Docs/assets/interface.png" width="100%" alt="The Hipparchus window: the Serra do Mar behind São Paulo in the Fragmented Urban style, shaded relief in the Admiralty palette. Left, the locator, the frame and the saved places; centre, the map; right, the layer list, the sixteen style swatches, and the controls — palette, quality, line weight at 1.16x, relief over buildings, and a page set to 600 dpi. The floating Locator shows the same ground on Apple Maps. The status bar reads 8 layers, 11,137 features, -305 m to 1,388 m.">

<table>
  <tr>
    <td width="50%"><img src="Docs/assets/gallery-hawaii-hypsometric.png" width="100%" alt="The island of Hawaii as filled elevation bands under relief shading, Mauna Kea and Mauna Loa reading as shields with the rift zones and the sea floor around them, from real elevation data"></td>
    <td width="50%"><img src="Docs/assets/gallery-amsterdam-fragmented-urban.png" width="100%" alt="Amsterdam's canals, rail fan and building footprints drawn from OpenStreetMap, on ground too flat to shade"></td>
  </tr>
</table>

The Python application is the specification. It is finished, it works, and its
454 tests are an executable description of the behaviour being ported. Anything
here that disagrees with it is a bug here.

**Status: the app is built and running.** Every online source, the composing
source stack, the sixteen presets, seventeen palettes over any of them, illuminated
contours, relief shading, an adjustable line weight, the three-column interface
and export at a real printed size are in, with 761 tests and the output checked
against real ground.

Every claim here is backed by a test or by a render someone can open. **Almost
none of them is a claim about the interface.** The window at the top of this
page was photographed by the author on his own Mac; it is not something the
build can produce, because the environment this was written in has no Screen
Recording permission and cannot capture any window. The model behind the window
is verified continuously, the layout is not, and "Verifying the app itself"
below is as close as anything headless gets to it.

## Download

[**Hipparchus 0.2.6**](https://github.com/tsevis/HipparchusMac/releases/latest)
— a disk image, on the releases page. Drag the app to Applications.

The build is **signed ad-hoc: no Developer ID, no notarisation.** It opens on
the machine that built it. On any other Mac, Gatekeeper refuses it, because a
downloaded image carries a quarantine flag and macOS cannot verify an ad-hoc
signature. Right-click the app and choose **Open**, or clear the flag:

```
xattr -dr com.apple.quarantine /Applications/Hipparchus.app
```

That is a reasonable thing to ask of yourself and an unreasonable thing to ask
of anyone else. Proper distribution needs an Apple Developer account, a
Developer ID certificate and `notarytool`; this repository does none of that,
and says so rather than shipping something that looks distributable and is not.
Building from source, below, has none of these problems.

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
"Twin Peaks San Francisco" — pick from what comes back, and press Render map. The
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

**The Locator**, in the Frame panel and also — via the map icon in the toolbar —
its own floating window, is a fourth way in: a real, live map of the whole
world, to drag and pinch rather than search or type. It starts at world scale
regardless of whatever area is already requested — a mirror of the main canvas
would put you back where you started — and every pan or zoom becomes the
requested area, the same one Render map then fetches. The area can also change
from elsewhere — a search result, a saved place, typed coordinates, a pasted
clipboard — and the Locator moves to show that too, without that reflected move
being mistaken for a fresh drag and bouncing back out to the requested area a
second time. A region this view is *told* to show is marked before it is set;
the delegate callback that same `setRegion` triggers checks that mark and skips
reporting it.

It first shipped as a row inside the Frame panel's `List`, and did not actually
pan or zoom there: a `List` on macOS owns a real `NSScrollView`, which competes
with `MKMapView`'s own pan and magnify recognizers for the same mouse-down-drag
and scroll events, so the map drew correctly but never moved. It now sits above
the list as a plain sibling view, with no scroll view left to compete with, and
the floating window is a second way to reach the same live map, undocked from
the list entirely and free to be positioned wherever is convenient — opening it
again brings the same window forward rather than spawning another, and closing
it keeps the map's position rather than resetting to the whole world.

Nobody can drag this map in a screenshot-less environment either, so it is
verified the same way as the rest: driving the real `Coordinator` and a real
`MKMapView` directly, establishing the world-scale starting region exactly as
the live view does, then setting a region the same way a finished pan or zoom
gesture would, with no mark beforehand.

```sh
Hipparchus.app/Contents/MacOS/Hipparchus --verify-locator 37.976,23.735,0.32,0.32
Hipparchus.app/Contents/MacOS/Hipparchus --verify-locator 19.6,-155.4,1.4,1.4
```

```
reported: 23.458214,37.816000 -> 24.011786,38.136000  (0.5536° × 0.3200°)
reported: -156.413278,18.900000 -> -154.386722,20.300000  (2.0266° × 1.4000°)
```

The starting region is never reported back, and the simulated gesture is,
with the requested latitude span exact and the longitude span wider by
exactly the view's aspect ratio divided by the cosine of latitude — Mercator's
own distortion, not an error. The first version of this check called the
delegate a second time by hand after `setRegion`, on the assumption a windowless
view might not fire it on its own; it does, synchronously, and that redundant
second call landed after the real one had already cleared the mark, reading
as a second, unmarked change and failing every run. That was a bug in the
check, not in the Locator, which never calls the delegate itself.

A locator that starts at world scale makes it an easy accident to drag out to
the whole planet and press Render map. Past a few hundred square degrees —
comfortably more than a large country — OpenStreetMap is refused outright
rather than merely warned about: `FetchCost`'s own linear time estimate would
otherwise answer with something like "3,366,000 minutes," which reads as
broken rather than as the plain no this is instead. Turning OpenStreetMap off
and fetching Elevation or another source alone still works at any size.

The CLI does the same thing headlessly and writes PNG, SVG, PDF and a
diagnostics JSON:

```sh
swift run -c release hipparchus-cli santorini
swift run -c release hipparchus-cli --all --out out
swift run -c release hipparchus-cli --bbox 23.2,36.3,24.2,37.1
```

Build it in release. In debug the contour tracer is about thirty times slower,
which is the difference between a six-second fetch and a three-minute one.

Everything the window can do to a sheet, it can do too, which is how the
choices above were checked without a window to look at:

| | |
|---|---|
| `--hillshade` | shade the relief; `--sun az,alt`, `--exaggeration`, `--shade-bands` |
| `--relief-on-top` | draw the shading over the buildings rather than under |
| `--palette <name>` | recolour a preset; `--list-palettes` |
| `--line-weight <x>` | multiply every stroke |
| `--paper <name>` `--dpi <n>` `--portrait` | the sheet, for all three formats |
| `--plugins <dir>` | load a style pack, so its presets and places can be named |
| `--streets` | stack OpenStreetMap onto the elevation |
| `--simulated` | a generated field, needing no network at all |

```sh
swift run -c release hipparchus-cli everest --hillshade \
    --paper "24 × 36 in" --portrait --dpi 300 --out out
swift run -c release hipparchus-cli kefalonia --plugins Plugins \
    --preset "Admiralty Chart" --hillshade --out out
```

Keep a `--streets` area small: a window of 0.04° × 0.03° over San Francisco
returns 29,000 features in about half a minute, and Overpass is shared hardware
run on donations.

## Sources are fetched together

Every ticked source is fetched **concurrently**. They used to run one after
another, which made a fetch cost the sum of its sources rather than the slowest
of them — with six ticked, OpenStreetMap's retry budget, then the imagery's,
then the earthquakes', in series, and the reasonable ones waiting behind
whichever was having a bad day. They share nothing but the network, so there
was never a reason to serialise them. Seoul at 0.09° × 0.05° with streets and
elevation went from 36 s to 13 s.

Two things survive the change and are tested:

- **The plan's order still decides the merge.** Collections are sorted back into
  the order they were asked for before merging, because the merge takes the
  first answer for keys a single source owns — the contour interval, the
  elevation model. Without that, whichever provider happened to answer fastest
  would decide what the sheet says.
- **Cancelling still keeps what was already paid for.** What finished before the
  cancel is drawn; what was still waiting is stopped. What is gone is the old
  guarantee that a source *behind* the cancel never starts, because there is no
  longer a queue to be behind.

One mirror was dropped along the way: `overpass.kumi.systems` stopped answering
at all — never replying rather than refusing — so every attempt paid the full
60-second timeout waiting for a host that was never going to answer, three
times over. Worth putting back the day it works again.

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

Addis Ababa, Everest and the Myrtoan Sea are verification areas rather than
saved places — the sidebar's list is the eleven cities and island groups worth
returning to — so reach them by `--bbox`, or by pasting the coordinates above.

Athens, Addis Ababa and Everest yield no bathymetry; the Myrtoan Sea yields five
summits rather than two dozen. Santorini's Illustrator layers come out as 178
contours, 798 index contours, 7 bathymetry and 24 summit labels — the same counts
the Python's own screenshot shows — and its longest contour is 8,097 vertices,
arriving whole.

Beyond that, fixtures compare this port against something other than my reading
of it. Most are the Python itself:

- **Contours** — the same field traced by both, matching line for line and vertex
  for vertex across five levels, 24 lines and 644 vertices.
- **Elevation bands** — areas matching Shapely to one part in 10⁹, and polygon and
  hole counts matching exactly, over a cone and a crater.
- **Illumination** — every run boundary and weight around a lopsided ring, for the
  four profiles the shipped presets use.
- **The simulated field** — the same seed producing the same ground.
- **Terrarium decoding** — a real AWS tile decoded to the same metres by Core
  Graphics, skia and PIL.

Two have no Python to be in parity with, and are pinned against something else:

- **Hillshade** — against the published ESRI/GDAL slope-aspect-zenith formulation,
  because that repo names the layer and computes it nowhere.
- **Palettes** — against `Scripts/build-style-packs.py`, whose `sheet()` is the
  same derivation and ships the four style packs. Two copies of one function
  drift; this is what stops them.

Regenerate them with the scripts in `Scripts/`. A diff there means one of the two
implementations changed; find out which before accepting it.

## Gallery

The same two areas in a light preset and in Night, rendered by the app's own
pipeline — `--bbox … --preset … --render-to`, not screenshots of a window.

<table>
  <tr>
    <td width="50%"><img src="Docs/assets/kyiv-light.png" width="100%" alt="Kyiv in the Hypsometric Relief preset: the Dnieper and its islands, the street grid over filled elevation bands"></td>
    <td width="50%"><img src="Docs/assets/kyiv-dark.png" width="100%" alt="The same frame of Kyiv in the Night preset: lit streets over a dark ground, the Dnieper reading as a void"></td>
  </tr>
  <tr>
    <td align="center"><em>Kyiv · Hypsometric Relief · 240,403 features</em></td>
    <td align="center"><em>Kyiv · Night · the same fetch, restyled</em></td>
  </tr>
  <tr>
    <td width="50%"><img src="Docs/assets/ionian-light.png" width="100%" alt="Lefkada and Kefalonia in the Coastal Survey preset: coastline, bathymetry and relief from minus nine to 1596 metres"></td>
    <td width="50%"><img src="Docs/assets/ionian-dark.png" width="100%" alt="The same Ionian frame in the Night preset, the islands against an unlit sea"></td>
  </tr>
  <tr>
    <td align="center"><em>Lefkada &amp; Kefalonia · Coastal Survey · −9 m to 1,596 m</em></td>
    <td align="center"><em>Lefkada &amp; Kefalonia · Night</em></td>
  </tr>
</table>

Three cities in three of the palettes named after people who drew the world, or
went and looked at it. One preset — Fragmented Urban — supplying the geometry
for all three, and the colour coming from somewhere else entirely, which is what
having colour as an axis of its own is for.

<table>
  <tr>
    <td width="33%"><img src="Docs/assets/gallery-jerusalem-ptolemy.png" width="100%" alt="Jerusalem in the Ptolemy palette: apricot buildings on cream vellum, violet contours crossing the Judean hills from 561 to 839 metres, the Old City walls at the centre"></td>
    <td width="33%"><img src="Docs/assets/gallery-manama-powell.png" width="100%" alt="Manama in the Powell palette: terracotta buildings on a sage ground, the Gulf pale around reclaimed land, the causeway running north to Muharraq"></td>
    <td width="33%"><img src="Docs/assets/gallery-singapore-vespucci.png" width="100%" alt="Singapore in the Vespucci palette: terracotta and orange on a near-black ground, Marina Bay and the Singapore River in blue, Gardens by the Bay to the east"></td>
  </tr>
  <tr>
    <td align="center"><em>Jerusalem · Ptolemy · 25,873 features</em></td>
    <td align="center"><em>Manama · Powell · 27,530 features</em></td>
    <td align="center"><em>Singapore · Vespucci · 21,538 features</em></td>
  </tr>
</table>


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
up until the moment **Render map** is pressed — that button is asking the app
to act on what is actually on screen, so it reads the canvas's current pan,
zoom and rotation, sets the area to whatever ground that implies, and resets
the view to a plain fit before fetching. Without this, zooming out and pressing
Render map re-fetched the same area as before while the screen still showed the
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

## Keyboard

Every shortcut drives a control that is also on screen. A shortcut for
something with no button is a secret, not a feature.

| | |
|---|---|
| `⌘↵` | Render map |
| `⌘.` | Cancel a running fetch |
| `⌘L` | Open the Locator |
| `⌘F` | Search for a place |
| `⇧⌘V` | Paste coordinates |
| `⌘1`…`⌘9` | Saved places, in sidebar order |
| `⌥⌘1`…`⌥⌘7` | The rest of them — `⌘0` is Fit to Window, so the run continues on the option key rather than stealing a shortcut everyone already knows |
| `⌘E` / `⇧⌘E` / `⌥⌘E` | Export SVG / PDF / PNG |
| `⌘+` / `⌘−` / `⌘0` | Zoom in, out, fit to window |
| `⌘[` / `⌘]` | Turn the view |
| `⌘Z` / `⇧⌘Z` | Undo, redo |
| `⌘,` | Settings |

The floating Locator has its own set, written on the map itself in the lower
left so they need no looking up:

| | |
|---|---|
| `↑` `↓` `←` `→` | Move a fifth of the view |
| `⇧` + arrows | Move three times as far |
| `+` / `−` | Zoom |
| `0` | Back to the whole world |
| `D` | Draw an area by dragging |
| `esc` | Leave draw mode |
| `⌘↵` | Render what is chosen |

## Settings

⌘, opens four preferences, kept in `settings.json` in the Python's own format
so the file is shared between the two applications:

- **Cache ceiling**, in megabytes. The oldest answers are dropped once the
  cache passes it. Defaults to 4 GB, as the Python does.
- **Requests a second** to shared services. Overpass runs on donated hardware
  and asks for one; a source's own settings can still override it.
- **Where things are kept** — the app is sandboxed, so its preferences, saved
  styles, plugins and cache all live inside a container nobody would navigate
  to by hand. Each has a Show button.

## Undo

Everything a person can do is undoable — the area, however it was set; ticking a
source and every inline setting; the preset and the quality; hiding a layer;
and fetching a map. ⌘Z and the Edit menu
name the action they will take back: "Undo Choose Place", "Undo Change Preset",
"Undo Fetch Map".

Two rules carry the design. A stepper drag or a typed coordinate coalesces into
one action, because it was one intention. And **undo of a fetch restores the
previous scene from a bounded store rather than re-fetching** — undo must never
cost minutes of Overpass time to take back something that cost minutes of
Overpass time. Only the newest few scenes are kept, so undoing very far back can
reach a map that was let go; the status bar says so, and Render map redraws it —
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

## The page, and printing at a real size

Paper is stated in **inches**, and one description drives all three exports.
Pixels are inches × dpi for the bitmap, points are inches × 72 for the PDF — so
a PDF carries physical size and ignores the resolution entirely — and SVG keeps
taking pixels, because that is what a viewport is. A sheet asked for at 24 × 36
is the same sheet in every format.

Ten sheets, from A4 to the 24 × 36 inches a print shop treats as a standard
poster, and four resolutions. Everest at 24 × 36 and 300 dpi is a 7,200 ×
10,800 PNG and a PDF whose MediaBox is exactly 1728 × 2592 points: 78
megapixels, drawn in about a second and a half.

Resolution is a choice from four rather than a text field, because a field
invites 1200 dpi on a poster — 1.2 gigapixels — and Core Graphics does not
refuse that politely: it returns a nil context, and the export reports "could
not render" for a request nobody could satisfy. The cost is measured before
drawing, shown under the controls in inches, pixels and megapixels, and refused
past 120 megapixels with a message that says what was asked for and points at
SVG or PDF, which have no pixels to run out of.

This is a divergence: the Python's paper presets are a table of pixel sizes,
which is A4 at 300 dpi with the 300 left implicit, and it gives the other two
exporters nothing to work from. Before this, PNG was hardcoded to 2400 × 1800
and PDF to A4 in points whatever the Page section said.

## Page furniture

The SVG export can carry a title block, a scale bar, a north arrow and a simple
legend, composed for the chosen sheet, with the orientation turning the sheet
rather than the map. Ported from
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

## Relief shading

`terrain_hillshade` was named in the draw order, the layer panel and the file
source list, and produced by nothing — the layer existed so a hillshade
polygonised in QGIS could be dropped in as a file. It is now computed from the
elevation grid the terrain provider already fetches, and from the simulated
field too.

Horn's method, lit from the north-west at 45° by default, because lit from the
south-east most readers see the valleys as ridges — that inversion is a
property of the reader, not of the data, which is why the default matters more
than it looks like it should. The shade is **banded into filled polygons**
rather than rasterised: this application draws vectors and exports SVG and PDF,
and a shaded raster has nowhere to go in either. Banding it through the same
tracer elevation already uses means the tones carry `band_index`, so they ramp
along a preset's two-stop fill with no renderer change at all.

Off by default — shading lands under the contours and changes the look of every
sheet, which is a choice about the drawing rather than a fact about the ground.
Elevation → Relief shading, with sun bearing, sun height and relief stretch
beside it.

Two things were learned by looking rather than by reasoning:

- **Tones band on a fixed 0…1 scale, not the observed range.** Stretching the
  observed range sounds right — gentle ground never reaches either extreme — and
  it turns "how much relief is there" into "always maximum contrast". Amsterdam
  has 25 m of relief across 14 km, most of it rooftops in a surface model and
  step noise from the DEM, and stretched banding covered the whole city in a
  mottle that looked like terrain and was not. A shade value is physically
  meaningful, so absolute edges are too: Everest reaches all seven tones and
  Amsterdam two. A sheet reaching fewer than two is not shaded at all.
- **In a dense city the shading is buried under the buildings.** Relief is ground
  and buildings sit on it, so that draw order is right, and twenty thousand
  opaque building fills leave the shading showing in the parks and the street
  corridors and nowhere else. **Relief over buildings** lifts it over the whole
  sheet instead; labels stay on top either way.

There is no Python counterpart to be in parity with — that repo names the layer
in three places and computes it in none — so the fixture pins the published
ESRI/GDAL slope-aspect-zenith formulation, computed independently, against the
dot-product form the Swift is written in. Two pieces of algebra for one number,
agreeing to 1e-12 across 6,864 cells of tilted, curved, noisy and holed ground.

## Palettes, and line weight

A preset here is a whole sheet: thirty-seven layer styles, colour and weight and
opacity chosen together. That makes "the same map in other colours" a thing you
cannot ask for — you can only pick a different sheet, and its geometry and
emphasis come with it.

`Scripts/build-style-packs.py` had already solved this at build time. Its
`sheet()` derives all thirty-seven styles from eight named colours, which is
exactly a palette engine, run once by a script and frozen into JSON. The same
function now exists in Swift and runs at render time, so any of seventeen palettes can
be laid over any preset without a build step. The preset keeps its geometry
profile, which is what a preset still is once colour has been lifted out of it.

Two copies of one derivation drift, and the drift would be invisible: a green
four units off looks like a green. So the parity fixture is the script's own
output and the test compares every layer and every channel. Making them agree
turned up two things worth knowing: the script defaults an unstated stroke
colour to its module-level `INK` rather than to the sheet's own ink, and
Python's `round()` is half-to-even where Swift's `.rounded()` is
half-away-from-zero — a channel landing on 40.5 is 40 there and 41 here.

**Line weight** is one multiplier over every stroke, 0.25× to 4×, beside
Quality. The preset owns the *relative* weights — a motorway stays the same
multiple of a service road at every setting — and this moves only the absolute
scale, which belongs to the medium: the weight that reads on a screen is not the
weight that reads on a metre of paper, and a sheet exported at 24 × 36 has
hairlines a third of a millimetre wide. Applied to the built scene, so it is
live: moving the slider redraws without re-simplifying a quarter of a million
features.

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

## Plugins, and style packs

A plugin is a folder with a `plugin.json` in it, contributing **presets** — in
the same format the app writes when you save a style — and **places**. Drop one
into the plugin folder (Style → Plugins → Show plugins folder) and it appears
beside the built-in sixteen. `PluginLoader` gives fault isolation: one broken
plugin costs exactly itself, is named under Style → Plugins, and the rest load.

Four packs live in `Plugins/`, generated by `Scripts/build-style-packs.py`:
**Tsevis Palette** (two styles and five Ionian islands), **Nautical**,
**Duotone Press** and **High Contrast**. Every one derives all thirty-seven
layer styles from a handful of named colours rather than choosing each — a
palette picked layer by layer drifts, and one derived by mixing cannot.

**A deliberate divergence.** In the Python a plugin is a module imported at
run time. A sandboxed, hardened-runtime app cannot do that: library validation
refuses code not signed by the same team. So user plugins here are declarative
and built-in ones are Swift types. Little is lost — the Python's plugin
protocol has one implementation, whose `register()` returns `None` — and what
is gained is that a plugin cannot crash the app or read your files.

## What is not here

The Python is the specification, and a port that quietly drops things is worse
than one that says which. Everything below exists there and not here **on
purpose**; anything not listed is either ported or a bug. This list was
assembled by auditing the Python module by module, because until that audit
three layers were styled by every preset and populated by nothing, and nobody
had noticed.

Three entries have since left it, because they stopped being true: **saved
presets**, **plugins** and most of the **settings store** all exist now. A list
of what is missing is only worth having if it is kept honest in both
directions.

**Whole features, not ported.**

- **Label font family and size, and device scale.** `core/settings_store.py`
  carries them and the Settings tab exposes them. The two knobs from it that
  actually change a fetch — the Overpass timeout and rate — are here, along with
  the cache limit and the preview tolerance; what is missing is the typography,
  which macOS mostly answers already.
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
hierarchy caps each class separately, `ferry_routes` is its own layer,
footprints are divided
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

## The derived layers, and why they are gone

The Python invents four layers from the map rather than fetching them: Voronoi
cells around the buildings, a Delaunay mesh between road junctions, a hex grid,
and packed circles. This port had all four, built on `GEOSVoronoiDiagram` and
`GEOSDelaunayTriangulation`.

They have been **removed**. They made a mosaic of a map, which is a different
program from this one, and every one of the sixteen presets left them switched
off — in this port and in the Python, where nothing outside a test ever turned
one on. Keeping a feature nobody enables costs a panel, a set of switches, a
GEOS dependency surface and forty tests, all to produce a look this app is not
for.

This is the port's one deliberate *subtraction* from the Python, as distinct
from the substitutions listed above. A preset written by the Python app still
carries `derive_voronoi` and its companions; those keys are simply ignored now,
and such a preset still loads with everything else intact.

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
