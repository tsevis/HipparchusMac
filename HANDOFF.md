# HipparchusMac — continuing

Open a new chat with the working directory set to
`/Users/tsevis/AI/ClaudeCode/HipparchusMac` and paste everything below the line.

---

I am continuing work on **HipparchusMac**, a native macOS rewrite of a finished
Python application. Read `README.md` and `KICKOFF.md` first — the kickoff is the
original brief and its fifteen numbered details are still the standing rules.
`/Users/tsevis/AI/ClaudeCode/Hipparchus` on `main` is the Python, and it remains
the specification: anything here that disagrees with it is a bug here, unless the
divergence is documented as deliberate.

## Where it is now

Working, committed, and green: 454 tests, `swift test -c release` in about two
seconds. 62 Swift files, roughly 14 000 lines.

Built: the composing source stack; Overpass, terrain tiles, USGS earthquakes,
Celestrak ground tracks, NASA GIBS, simulated terrain; the file-backed sources
(GeoJSON, shapefile, MBTiles/PMTiles vector tiles, OSM PBF); the sixteen presets
and quality profiles; illuminated contours, smoothing, simplification; the four
derived artistic layers; the road hierarchy; the three-column interface with a
place search; SVG, PDF and PNG export; session persistence.

Four parity fixtures compare this port against the Python directly rather than
against anyone's reading of it — contours, elevation bands, terrarium decoding,
and the simulated field. Regenerate with the scripts in `Scripts/`.

## The one thing nobody has checked

**No one has ever seen the interface.** This environment has no Screen Recording
permission, so no window of any app can be captured — I confirmed that by failing
to capture other applications too, not just this one. Every claim about the app is
therefore about its *model*, verified headlessly, and never about its layout.

Two flags exist for that headless verification, and they are the right tool for
anything you cannot see:

```bash
Hipparchus.app/Contents/MacOS/Hipparchus --bbox 25.32,36.33,25.50,36.48 --render-to out.png
Hipparchus.app/Contents/MacOS/Hipparchus --search "Twin Peaks San Francisco" --render-to out.png
Hipparchus.app/Contents/MacOS/Hipparchus --sources terrain_tiles --derive hex --preset "Contour Study" --render-to out.png
```

They drive the window's own model and write the PNG into the app's container
(`~/Library/Containers/com.hipparchus.HipparchusMac/Data/Documents`), because the
app is sandboxed and may only write where it has been pointed.

**Please start by asking me to run the app and look at it**, or tell me exactly
what to check. Do not claim the interface works.

## What I want next

### 1. The place search and Update map buttons

They are written — `PlaceSearchField.swift`, and the `Update map` toolbar item in
`ContentView.swift` — and the search path is verified headlessly: MapKit answers
from inside the sandbox, the frames are sensible, and searching then drawing
produces the right map. What has never been confirmed is that they *appear and
work in the window*.

Make them right. Specifically:

- Confirm the search field renders in the toolbar, accepts typing, and shows its
  results popover. A `ToolbarItem` holding a `TextField` is not a common thing to
  do and may need to become a `.searchable` or a plain view outside the toolbar.
- Confirm `Update map` is reachable, enabled when it should be, and that ⌘↵ works.
- The results popover shows each place's name, where it is, and the frame it would
  give. Check it is legible and that picking one sets the area without fetching.
- Add a visible **Cancel** beside Update map while a fetch runs. It exists in the
  status bar; the design puts it where the eye already is.

If the toolbar approach fights SwiftUI, move the controls into a strip under the
toolbar rather than fighting it. The design's arrangement matters more than the
mechanism.

### 2. Undo, for every action

I want undo on everything a person can do. That is the substantial piece of work
in this handoff, and it wants designing before it is written.

What must be undoable:

- The area — from the search, from Option-drag on the canvas, from the coordinate
  boxes, from a saved place.
- Ticking and unticking a source, and every inline source setting.
- The preset, and the quality profile.
- Showing and hiding a layer.
- Each of the four derived-layer switches and their sizes.
- **Fetching a map.** Undo here must restore the previous scene, *not* re-fetch:
  a re-fetch could cost minutes of Overpass time, and undo should never be slower
  than the thing it undoes.

A strong hint, which you should evaluate rather than take on trust: `Session` in
`Sources/HipparchusRender/Session.swift` is already a `Codable` snapshot of every
choice the app holds — sources, paths, per-source settings, preset, quality,
hidden layers, area. A history of `Session` values plus the `RenderScene` each one
produced may be the whole undo stack, and would give redo for free. Registering
those with SwiftUI's `@Environment(\.undoManager)` would put ⌘Z and the Edit menu
in place without inventing a parallel mechanism.

Two things to get right, because they are what makes undo feel wrong when it is
wrong:

- **Coalescing.** Dragging a stepper from 60 to 120 is one action to a person and
  sixty to the model. Typing in a coordinate box is one action, not each keystroke.
- **Naming.** macOS puts the action name in the menu — "Undo Change Preset", "Undo
  Fetch Map". A menu that only ever says "Undo" is a menu that tells you nothing.

Write tests for the history itself: it is a value type over value types, and every
rule above can be tested without a window.

### 3. Two layers that are styled and never populated

The same defect I found and fixed for roads, twice more. Each is a preset
advertising a look it does not have:

- **`street_names`** — styled by all sixteen presets, given a label budget of 90 in
  `SceneBuilder`, ordered in the layer list, and nothing ever puts a label in it.
  Port `_street_labels` from `application/scene_builder.py`. The interesting rule
  is already written there: OSM splits a street into one way per block, so keeping
  only the longest run per name puts the label where the street is most legible
  instead of stamping it down the road forty times.
- ~~**`terrain_hillshade`** — named in the draw order and the layer panel, produced
  by nothing.~~ **Done.** The terrain provider now computes one from the elevation
  grid it already fetches and bands it into filled polygons, so the row fills.
  `Sources/HipparchusGeometry/Hillshade.swift`. It has no Python counterpart —
  that repo names the layer in three places and produces it in none — so it is a
  divergence in the port's favour, pinned against the published ESRI/GDAL
  formulation rather than against the Python.

### 4. Smaller things, in no particular order

- `export/profiles.py` and `export/svg_clean.py` are not ported. They add page
  composition and map furniture — scale bar, north arrow, margins — to the SVG.
  Worth reading before deciding whether the current exporter needs them.
- GeoParquet is deliberately unread; the README says why, and the app prints the
  one `duckdb` command that gets past it. Only revisit this with a real Overture
  file to test against — it needs a ZSTD decoder written from scratch, and a
  silently wrong decompressor is the worst possible outcome.
- The app writes to its container because it is sandboxed. If exports should land
  anywhere else, that is a save-panel and entitlement question.

## How I want you to work

Unchanged from the kickoff, and it has served well:

- Test-driven. Port the Python's tests before the module, and prefer a test that
  states the reason — the suite reads as an argument, not a checklist.
- **Verify by running, not by assuming.** When you cannot see something, say so
  plainly rather than claiming it works. Every visual claim in this repository is
  backed by a render someone can open.
- Small conventional commits (`feat:`, `fix:`, `refactor:`). **Do not push.**
- Measure before deciding. Three of the better decisions in this port came from
  checking real data first — the road-class counts, the Aegean's 2 055 member
  ways, and MapKit answering "Everest" with a 141-metre radius.
- Say what you left out and why. Do not narrow scope silently.
- Ask before architectural choices the kickoff has not already made.

## Things that are not bugs

Read the README's own list first. The short version: faint diagonals in elevation
are void-fill seams in the source mosaic; in cities the highest ground is a
building, because the mosaic is a surface model; Cancel cannot abort a request
already in flight; a ferry route crosses open water in a straight line because it
does; and no built-in preset enables a derived layer — that is true of the Python
too, and the Derived panel is the switch.
