# HipparchusMac — kickoff

Open a new chat with the working directory set to
`/Users/tsevis/AI/ClaudeCode/HipparchusMac` and paste everything below the line.

---

I want to build **HipparchusMac**: a native macOS app in Swift, in this repo at
`/Users/tsevis/AI/ClaudeCode/HipparchusMac`. It is empty apart from this file.

It is a native rewrite of a finished, working Python application. **Read that
codebase before writing any Swift.** It is the specification, it is thorough,
and its 454 tests are an executable description of the behaviour you are
porting. Do not re-derive decisions that were already made and tested there.

## The existing app

`/Users/tsevis/AI/ClaudeCode/Hipparchus`, on `main`, at version 0.3.2.

A desktop vector-cartography tool. You choose an area of the world; it fetches
map data from several online sources, renders a preview, and exports layered,
Illustrator-editable SVG. 13,816 lines of Python across 40 test files.

Read these first, in order:

- `README.md` — what it is, with a gallery of real output and two screenshots of
  the running interface. **Those screenshots are your UI reference.** Match that
  layout; do not invent a new one.
- `CHANGELOG.md` — what 0.3.2 added, and a "Known limits" section stating what
  each source cannot do.
- `documents/NextStepsClaude.md` — outstanding work, known source
  characteristics that are not bugs, and known-good reference values for
  checking your output against reality.
- `documents/interface-proposal.png` — the annotated design the interface was
  built from, with the reasoning behind each decision.
- `src/hipparchus/geometry/` — contours, elevation bands, illumination, orbits.
  Nearly all portable arithmetic.
- `src/hipparchus/data_sources/` — every source, with its URL and its quirks.
- `tests/` — port test-first: translate a test to XCTest, translate the module,
  make it green.

## Architecture already decided

- **SwiftUI**, `NavigationSplitView`. The interface is a three-column layout and
  maps onto it almost one to one.
- **GEOS as an XCFramework. Do not reimplement planar geometry.** Shapely is a
  binding to GEOS, and the Python uses only `polygonize`, `unary_union`,
  `intersection`, `difference`, `buffer`, `is_valid`, `is_empty`,
  `representative_point`, `interpolate`, `simplify`, `STRtree` and WKB — all in
  the GEOS C API. `GEOSVoronoiDiagram` and `GEOSDelaunayTriangulation` also
  replace the SciPy usage.
- **Core Graphics** for the canvas and for decoding PNG tiles (`CGImageSource`).
  Skia appears in only three places in the Python and is not needed. Metal later
  for the dense contour sheets if it proves worth it.
- **SF Symbols** for icons. The Python has a hand-drawn icon module
  (`ui/icons.py`) that exists only because Tk had nothing — delete that idea.
- **MapKit** for the locator. The Python one draws a graticule with no coastline
  because it had no data to hand; MapKit does it properly.
- **Core Graphics PDF export** alongside SVG, since it is nearly free.
- No Python at runtime, no embedded interpreter.

## First slice, before anything else

One vertical path, proving the whole chain end to end:

**terrain tiles → contours → Core Graphics canvas → SVG export**

It exercises networking, the GEOS bridge, the geometry, the renderer and the
export in one narrow line. Get it green and tested before touching the other
sources, the source stack UI or presets.

## What the interface is

Not a menu of modes. A map is **composed**:

1. **Sources stack, they do not replace.** Ticking Elevation onto a street map
   adds contours; it never discards the streets. This replaced a model dropdown
   that silently threw the rest of the map away, and it is the single most
   important idea in the design.
2. Each source carries **its own settings inline**, behind a disclosure.
   File-backed sources sit behind a further disclosure — four always-visible
   cards for the minority case pushed everything else off the panel.
3. The layer list is **derived from the map that was actually fetched**, grouped,
   with counts, and empty layers shown as "none here" so an empty map explains
   itself.
4. Style is chosen from **thumbnails rendered from the presets themselves**, so
   a preset cannot advertise a look it no longer has.
5. The map gets the room. Drag to pan, scroll to zoom, modifier-drag to draw a
   new area; coordinates stay one disclosure away.
6. A **locator** answers "where am I?" with the area marked on the world.
7. **Progress is per source, with a Cancel.**

## Details that each cost real debugging — carry them over

1. **WMS 1.3.0 with EPSG:4326 orders BBOX `lat,lon`.** Reversing it silently
   returns imagery of somewhere else.
2. **Terrain tiles are Web Mercator.** Rows are *not* evenly spaced in latitude;
   invert the projection per vertex or every contour lands north of where it
   belongs, worse away from the equator.
3. **Terrarium encoding:** `metres = R*256 + G + B/256 - 32768`.
4. **Elevation bands: do not hand-roll ring nesting.** Pad the field with a
   sentinel below its minimum so every contour closes, `polygonize` the rings,
   then keep faces whose interior is genuinely above the level by *sampling the
   field at each face's representative point*. Containment measured, never
   assumed. Holes and nesting then fall out for free.
5. **Contours carry slope aspect in their winding order** (high ground on the
   left). That is what lets illuminated contours vary stroke weight without
   dragging the elevation grid through the renderer. Winding survives clipping,
   simplification and smoothing; properties do not.
6. **Per-geometry colour and stroke weight must be built in lockstep with the
   geometry, after every other geometry step.** Clipping can split one feature
   and smoothing can drop one; either shifts a parallel array out of step. This
   bit twice.
7. **Contour interval must be a round 1/2/5 step** from the relief actually in
   view. A fixed interval empties a small window and floods a large one.
8. **Summits are land only.** Sea-floor highs have prominence too, and labelling
   two dozen "peaks" in open water is the result.
9. **Thinning a long path must not truncate it.** Cutting the vertex list short
   and jumping to the final vertex draws a chord straight across the shape.
   Seven of Santorini's contours exceed five thousand vertices.
10. **GIBS is rendered brightness, not calibrated radiance**, saturates over city
    cores, and is a coarse regional product — a city-sized frame upsamples into
    blocks. It also returns transient 500s; retry.
11. **Provenance is load-bearing.** Every source declares what it is —
    `measured`, `synthetic`, `uncalibrated`, `approximate` — on the features, the
    merged metadata, the scene and the exported diagnostics. Keep this. It is
    what stops a generated map being mistaken for a survey.
12. **Cancel cannot abort a request already in flight.** It skips sources that
    have not started, stops those that check between requests, and discards the
    result rather than drawing it. Say that plainly rather than implying more.
13. **Overpass dominates fetch time** — 331 s for a 0.32° area with every layer,
    of which 325 s was Overpass and 5 s was elevation. Warn before such a fetch.
14. **Fetch tiles concurrently** — 23 s serial became 5 s with a pool.
15. **Watch for import cycles between layers.** The Python had one that only
    fired when the data layer was imported first, and no test caught it because
    they all reached the application layer first.

## Sources and endpoints

- **OpenStreetMap** — Overpass, `https://overpass-api.de/api/interpreter`
- **Elevation** — `https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png`
  — no key, global, bathymetry included as negative values
- **Night lights** — NASA GIBS WMS,
  `https://gibs.earthdata.nasa.gov/wms/epsg4326/best/wms.cgi`, layer
  `VIIRS_Black_Marble`
- **Earthquakes** — USGS FDSN, `https://earthquake.usgs.gov/fdsnws/event/1/query`
- **Satellites** — Celestrak,
  `https://celestrak.org/NORAD/elements/gp.php?GROUP=stations&FORMAT=tle`

The file-based providers (`osmium`, `fiona`, `pyarrow`, PMTiles, MVT) are
optional and are the long tail. Ship the online sources first.

## Checking your output against reality

- **Athens** `23.575, 37.816 → 23.895, 38.136`: −4 m to 1091 m. Hymettus is the
  long N–S ridge east, Parnitha the mass north-west, Penteli north-east.
- **Santorini** `25.32, 36.33 → 25.50, 36.48`: −79 m caldera floor, 525 m rim.
- **San Francisco** `−122.53, 37.70 → −122.35, 37.84`: tops at 284 m; Twin Peaks
  is 282 m.
- **Addis Ababa** `38.65, 8.90 → 38.88, 9.10`: never below 2,075 m.
- **Everest** `86.85, 27.93 → 87.05, 28.06`: 5,060 m to 8,746 m.
- **Myrtoan Sea** `23.2, 36.3 → 24.2, 37.1`: reaches −1,310 m.
- **ISS**: latitude bounded at ±51.63°, altitude 414–424 km, period 92.95 min,
  drift ≈ −23.5° per orbit.

Faint straight diagonals in elevation data are **void-fill seams in the source
mosaic**, present before any contouring. Not a bug.

The elevation mosaic is a **surface** model: in cities the maxima are buildings.

## How I want you to work

- Test-driven, per the global rules in `~/.claude/rules`. Port the Python tests
  to XCTest before porting the module.
- Set the repo up properly first: Swift package or Xcode project, `.gitignore`,
  README, and a **reproducible** GEOS XCFramework build, documented.
- Small conventional commits (`feat:`, `fix:`, `refactor:`). **Do not push to
  GitHub** until I say so.
- Verify by running, not by assuming. When you cannot see something — and a GUI
  is the obvious case — say so rather than claiming it works. In the Python app
  a UI edit once disabled rendering entirely while every test still passed.
- Ask before architectural choices I have not already made above.

Start by reading the Python repo, the README screenshots and the interface
proposal, then come back with a plan for the repo skeleton and the first slice.
Do not write code until we have agreed the plan.
