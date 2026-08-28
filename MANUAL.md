# Hipparchus for macOS — Manual

**Version 0.5.0**

Hipparchus chooses an area of the world, fetches map data from public sources,
and draws it as a sheet you can export as layered, Illustrator-editable SVG —
or as PDF, PNG, or GeoJSON.

This manual is the how. [README.md](README.md) is the why, at length, and is
worth reading when a choice here looks arbitrary — most of them are not.

## Table of contents

1. [Installing](#1-installing)
2. [The window](#2-the-window)
3. [Choosing an area](#3-choosing-an-area)
4. [Choosing sources](#4-choosing-sources)
5. [Rendering](#5-rendering)
6. [Styling: presets, palettes, line weight](#6-styling-presets-palettes-line-weight)
7. [Layers](#7-layers)
8. [The page, and printing at a real size](#8-the-page-and-printing-at-a-real-size)
9. [Exporting](#9-exporting)
10. [The sea](#10-the-sea)
11. [Settings, undo and the keyboard](#11-settings-undo-and-the-keyboard)
12. [The headless renderer](#12-the-headless-renderer)
13. [Style packs](#13-style-packs)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. Installing

### From a disk image

Download the latest image from the
[releases page](https://github.com/tsevis/HipparchusMac/releases/latest) and drag
the app to Applications.

**The build is signed ad-hoc — no Developer ID, no notarisation.** It opens
without ceremony on the machine that built it. On any other Mac, Gatekeeper
refuses it: a downloaded image carries a quarantine flag and macOS cannot verify
an ad-hoc signature. Two ways past it, both one-time:

- **Right-click the app and choose Open**, then confirm. macOS remembers.
- Or clear the flag by hand:

  ```sh
  xattr -dr com.apple.quarantine /Applications/Hipparchus.app
  ```

This is a real limitation rather than an oversight. Distributing something a
stranger can double-click needs an Apple Developer account, a Developer ID
certificate and `notarytool`. The disk image is built so it *looks*
distributable; it says plainly that it is not.

### From source

You need **macOS 15 or later** and **Xcode 26 / Swift 6.2**. GEOS is committed as
a pre-built xcframework, so you need CMake only if you want to rebuild it.

```sh
git clone https://github.com/tsevis/HipparchusMac.git
cd HipparchusMac
swift build -c release      # the libraries and the headless CLI
```

For the app itself, install [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) — the Xcode project is generated from
`App/project.yml` rather than committed, so there is no project file to merge:

```sh
Scripts/install-app.sh      # builds in release, installs to /Applications
```

Or, to work on it in Xcode:

```sh
xcodegen generate --spec App/project.yml
open App/HipparchusMac.xcodeproj
```

To build a disk image, named for the version and the commit it came from:

```sh
Scripts/make-dmg.sh         # → dist/Hipparchus-0.5.0-<sha>.dmg
```

### Checking it works

```sh
swift test -c release       # 1068 tests, about two seconds
```

Run the suite in **release**. Contouring is a tight numeric loop over a grid and
the unoptimised build runs it roughly fifty times slower — release takes about
two seconds, debug about thirty. No test touches the network.

---

## 2. The window

Three columns.

- **Left — the frame.** Where you are looking: bounds, place search, the
  Locator, and saved places including every continent and ~195 countries.
- **Centre — the map.** What has been drawn. Zoom with `⌘+` / `⌘−`, fit with
  `⌘0`, turn the view with `⌘[` / `⌘]`.
- **Right — everything about how it looks.** The layer list derived from what
  was actually built, the sixteen style swatches, the palette, quality, line
  weight, relief options, and the page.

The **status bar** along the bottom is the honest summary: how many layers, how
many features, and the elevation range of the ground in view. When a fetch is
running it reports per source, so a slow five-minute fetch says *which* source is
slow rather than "Idle".

---

## 3. Choosing an area

Five ways, all equivalent — they set the same bounding box.

**Saved places.** `⌘1`…`⌘9` for the first nine in sidebar order, `⌥⌘1`…`⌥⌘7` for
the rest. (`⌘0` is Fit to Window, so the run continues on the option key rather
than stealing a shortcut everyone already knows.) The Map menu also carries
**World, the six continents and the Mediterranean**, and **all ~195 countries
grouped by continent**, as a cascade.

**Search.** `⌘F`, then a place name. Geocoding is Nominatim and Apple MapKit.

**The Locator.** `⌘L` opens a world map drawn from Natural Earth — no network, no
key, no tile policy. It follows the zoom into the 1:10m dataset, so a sea has its
islands rather than a coarse outline at every scale. Its own keys are written on
the map itself, lower left:

| | |
|---|---|
| `↑` `↓` `←` `→` | Move a fifth of the view |
| `⇧` + arrows | Move three times as far |
| `+` / `−` | Zoom |
| `0` | Back to the whole world |
| `D` | Draw an area by dragging |
| `esc` | Leave draw mode |
| `⌘↵` | Render what is chosen |

**Typed coordinates.** Edit the bounds directly in the frame panel, or paste a
pair with `⇧⌘V`.

**Keep it a sensible size.** Past roughly a couple of thousand square kilometres,
Overpass will not answer at all. The app says what a large area will cost before
you wait for it, and refuses the sizes that are refusals rather than warnings.
Elevation-only frames can be far larger — see
[A continent, or the whole world](README.md#a-continent-or-the-whole-world) in
the README.

---

## 4. Choosing sources

The Sources panel is the list of things that can answer for an area. Tick what
you want; each carries its own inline settings and its own idea of what it costs.

- **OpenStreetMap** via Overpass — roads, buildings, water, land cover, railways,
  places, and the `seamark:*` namespace.
- **Elevation** from Mapzen / AWS Terrain Tiles — contours, filled bands,
  hillshade, summit heights.
- **EMODnet Bathymetry** — real surveyed depth under European seas, blended into
  the elevation grid so bands, sub-sea contours and shading all improve at once.
- **NOAA CoastWatch ERDDAP** — sea surface temperature, and geostrophic surface
  currents.
- **Natural Earth** — coastlines, borders, rivers, lakes and place names at
  1:110m and 1:10m. What OpenStreetMap cannot answer for at continental scale.
- **USGS** earthquakes, **CelesTrak** satellite tracks, **NASA GIBS** night
  lights.
- **Local files** — shapefile, GeoJSON, `.osm.pbf`, vector tiles, Overture.
- **Simulated terrain** — a generated field needing no network. Not a measurement
  of anywhere, and the app says so.

**Sources are fetched together**, not one after another, and each reports its own
progress. A failure in one does not lose the others.

---

## 5. Rendering

`⌘↵` renders. `⌘.` cancels a running fetch.

**Quality** has four profiles, from `preview_fast` to `export_print`. They change
how hard the geometry pipeline works — simplification tolerance, smoothing
passes, and how many features a layer may put on screen — not what is fetched.
Preview while you compose; export when you mean it.

Nothing ever re-fetches silently. If an action needs data that has been let go,
the status bar says so and waits for you to press Render map.

---

## 6. Styling: presets, palettes, line weight

**Sixteen presets.** A preset is a whole sheet: `Clean Atlas`, `Terrain Study`,
`Hypsometric Relief`, `Relief Sheet`, `Contour Study`, `Coastal Survey`,
`Monochrome Figure Ground`, `Night`, `Technical Blueprint`, `Editorial Print`,
and others. Click a swatch to switch; the map redraws without re-fetching.

**Seventeen palettes**, over any of the sixteen. A preset owns the geometry and
the relative weights; a palette replaces the colour and keeps everything else.
That is why "the same map, in other colours" is something you can ask for.

**A layer no preset has named is derived rather than guessed.** The style tables
predate several of the layers the app can draw — the sea floor, the sea marks,
the isotherms, the borders, the ferry routes — so each of those is now derived
from what the preset itself already chose: the sea's layers from its water and
its darkest line on the sea, a border from its land, the contours from the high
end of its elevation ramp. An explicit entry always wins. See
[A layer nobody styled](README.md#a-layer-nobody-styled).

**Line weight** is one multiplier over every stroke, 0.25× to 4×. The preset owns
the *relative* weights — a motorway stays the same multiple of a service road at
every setting — and this moves only the absolute scale, which belongs to the
medium. The weight that reads on a screen is not the weight that reads on a metre
of paper. Applied to the built scene, so it is live.

**Relief shading** is under the elevation source: sun azimuth and altitude,
vertical exaggeration, and how many tones between shadow and light. **Relief over
buildings** draws the shading above the built environment rather than under it,
for a city dense enough to bury it otherwise.

---

## 7. Layers

The layer list is **derived from the scene that was actually built**, not a fixed
checklist. A layer with nothing in it says "none here" rather than sitting there
ticked and blank, and an empty map can explain itself.

Layers are grouped: Terrain, Water & land, Sea marks, Ocean, Built, Movement,
Labels, Derived. Hiding one is undoable and does not re-fetch.

Draw order is fixed and deliberate — ground first, linework over it, labels last;
fills under the contours that describe the same ground, or the fills paint over
the lines. Every layer the app can produce has a rank, asserted by a test, so a
new source cannot quietly end up drawn last over everything.

---

## 8. The page, and printing at a real size

The page model is real sheets, not pixels-and-hope.

- **`--paper` / the Composition panel**: A4, A3, A2, Letter, Tabloid, 12 × 18 in,
  18 × 24 in, 24 × 36 in, Square, Canvas, or Custom.
- **Inches**, for an aspect no named sheet has — 20 × 12 is 5:3.
- **dpi** sets the raster's pixels and the SVG's viewport. A PDF carries points
  at 72 to the inch regardless, so a 20 × 12 sheet is 1440 × 864 points whatever
  dpi sized the bitmap beside it.
- **Portrait or landscape**, and a margin ratio.

**Page furniture** — title, subtitle, scale bar, north arrow, legend — is
optional and off by default, except the not-for-navigation notice, which is on by
default when it applies.

---

## 9. Exporting

| | |
|---|---|
| `⌘E` | SVG — layered, with each layer a named group |
| `⇧⌘E` | PDF — drawn, not photographed |
| `⌥⌘E` | PNG |

The SVG is the point of the application: one `<g>` per layer, named as the layer
is named, so Illustrator, Inkscape and Affinity Designer all open it as an
editable document rather than as a picture.

**GeoJSON export** writes the scene as data rather than as ink — either one file
or one file per layer, carrying the simplestyle properties each layer was drawn
with. That is how you check what the app actually decided, and it is how the two
applications are compared.

Every exported sheet carries **the sources that actually drew it**, so a file's
credits describe that file rather than the application in general.

---

## 10. The sea

OpenStreetMap describes a coast as open ways, not as a filled ocean, so a coastal
sheet drawn from the linework alone has a line where the water should be.
Hipparchus infers the sea from the coastline and fills it.

Beyond that:

- **Real bathymetry** from EMODnet under European seas, with **graded
  provenance**: each feature carries what fraction of it sits on a real survey
  rather than a coarse global grid.
- **Depth bands** — the sea's mass, as a ramp of its own rather than the land's
  borrowed.
- **Sea marks** as chart symbols to the S-57 object model: a can for a port hand
  mark, a cone for starboard, the four cardinal topmarks, a light's flare, a
  wreck's three masts. **Shape carries the meaning and colour does not**, so the
  marks survive flat light, a photocopier, and colour-blind eyes.
- **Surface currents** as streamlines, integrated rather than animated, with
  speed becoming stroke weight along each line.
- **Sea surface temperature** as filled bands and isotherms.

**NOT FOR NAVIGATION** appears on any sheet carrying depths, marks or currents,
and on no other. It is on by default, and the machine-readable claim survives
even when the words are switched off. This is not a charted survey and is not
corrected by Notices to Mariners.

---

## 11. Settings, undo and the keyboard

### Settings (`⌘,`)

No Apply button — a change takes effect as it is made.

- **Cache ceiling** in megabytes; oldest answers dropped past it. Defaults to
  4 GB.
- **Requests a second** to shared services. Overpass runs on donated hardware and
  asks for one.
- **Where things are kept.** The app is sandboxed, so preferences, saved styles,
  plugins and cache live in a container nobody would navigate to by hand. Each
  has a Show button.

Settings are kept in `settings.json` in the Python application's own format, so
the file is shared between the two.

### Undo (`⌘Z` / `⇧⌘Z`)

Everything a person can do is undoable — the area however it was set, ticking a
source and every inline setting, the preset, the quality, hiding a layer, and
fetching a map. The menu names what it will take back: "Undo Choose Place",
"Undo Change Preset", "Undo Fetch Map".

**Undo of a fetch restores the previous scene from a bounded store rather than
re-fetching.** Undo must never cost minutes of Overpass time to take back
something that cost minutes of Overpass time. Only the newest few scenes are
kept, so undoing very far back can reach a map that was let go; the status bar
says so, and Render map redraws it.

### Keyboard

Every shortcut drives a control that is also on screen. A shortcut for something
with no button is a secret, not a feature.

| | |
|---|---|
| `⌘↵` | Render map |
| `⌘.` | Cancel a running fetch |
| `⌘L` | Open the Locator |
| `⌘F` | Search for a place |
| `⇧⌘V` | Paste coordinates |
| `⌘1`…`⌘9` | Saved places, in sidebar order |
| `⌥⌘1`…`⌥⌘7` | The rest of them |
| `⌘E` / `⇧⌘E` / `⌥⌘E` | Export SVG / PDF / PNG |
| `⌘+` / `⌘−` / `⌘0` | Zoom in, out, fit to window |
| `⌘[` / `⌘]` | Turn the view |
| `⌘Z` / `⇧⌘Z` | Undo, redo |
| `⌘,` | Settings |

---

## 12. The headless renderer

Everything the window can do to a sheet, `hipparchus-cli` can do too — which is
how most of the choices in this manual were checked without a window to look at.

```sh
swift run -c release hipparchus-cli santorini
swift run -c release hipparchus-cli --bbox 23.2,36.3,24.2,37.1
swift run -c release hipparchus-cli --all --out out
```

**Build it in release.** In debug the contour tracer is about thirty times
slower — the difference between a six-second fetch and a three-minute one.

| | |
|---|---|
| `--bbox w,s,e,n` | an arbitrary area, in degrees |
| `--preset <name>` | style preset; `--list-presets` |
| `--palette <name>` | recolour a preset; `--list-palettes` |
| `--quality <key>` | `preview_fast`, `preview_high`, `export_clean`, `export_print` |
| `--hillshade` | shade the relief; `--sun az,alt`, `--exaggeration`, `--shade-bands` |
| `--relief-on-top` | draw the shading over the buildings rather than under |
| `--line-weight <x>` | multiply every stroke |
| `--paper <name>` `--dpi <n>` `--portrait` | the sheet, for all three formats |
| `--inches <w>x<h>` | a sheet of exactly these inches, for an aspect no named sheet has |
| `--size <WxH>` | exact output size in pixels, instead of a sheet |
| `--pixels <n>` | how finely to sample the ground; the knob that matters on a large frame |
| `--streets` | stack OpenStreetMap onto the elevation |
| `--natural-earth <path>` | coastlines, borders, rivers, place names |
| `--sea-temperature` `--currents` | the ocean scalar fields |
| `--simulated` | a generated field, needing no network at all |
| `--plugins <dir>` | load a style pack |
| `--geojson` `--geojson-layers` | also write the ground as data rather than as ink |
| `--out <dir>` | where to write (default `./out`) |

```sh
swift run -c release hipparchus-cli everest --hillshade \
    --paper "24 × 36 in" --portrait --dpi 300 --out out
```

Keep a `--streets` area small: 0.04° × 0.03° over San Francisco returns 29,000
features in about half a minute, and Overpass is shared hardware run on
donations.

---

## 13. Style packs

A style pack is a folder of JSON declaring presets, palettes and places. Point
the app at one and its presets can be named like the built-in ones:

```sh
swift run -c release hipparchus-cli kefalonia --plugins Plugins \
    --preset "Admiralty Chart" --hillshade --out out
```

Five ship in `Plugins/`: `cartographers`, `duotone-press`, `high-contrast`,
`nautical`, `tsevis-palette`.

---

## 14. Troubleshooting

**Gatekeeper refuses to open the app.** Expected — the build is signed ad-hoc.
Right-click and choose Open, or `xattr -dr com.apple.quarantine
/Applications/Hipparchus.app`. See [Installing](#1-installing).

**A fetch times out or returns nothing.** Overpass is shared hardware run on
donations and is sometimes busy. The app reports it rather than retrying
silently — a retry loop against someone else's server is rude. Try a smaller
area, or again later.

**The area is refused rather than warned about.** Past a certain size Overpass
does not answer at all, which is a statement rather than a delay. Elevation-only
frames can be much larger than street frames.

**The map is blank.** Check the layer list: if every row says "none here",
nothing was fetched for that area. Check the sources panel, and the status bar
for a per-source failure.

**A large frame looks coarser than expected.** Raise `--pixels`, or "Samples
across" in the app. There is a tile ceiling, and a world sheet asked for at the
default is sampled more coarsely than a small one.

**The installed app shows an old version number.** The install lagged the build.
Re-run `Scripts/install-app.sh`.

**Contours or bands take minutes.** You are running a debug build. Use
`-c release`.

---

## Licence

Hipparchus is released under the [MIT License](LICENSE). Copyright (c) 2026
Charis Tsevis.

That covers this repository's code and nothing else. **GEOS, which every polygon
operation here depends on, is LGPL-2.1 and is statically linked** — if you
redistribute a built copy, an obligation travels with it. The map data carries
its own terms too, ODbL among them. Both are set out in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
