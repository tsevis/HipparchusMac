# Handoff: fix the Locator floating window for real

## What the user actually wants (verbatim requirements, do not reinterpret)

1. **A pop-up (floating) window** showing a world map.
2. **Click a place on that map to select it.** Clicking shows the coordinates.
3. **"Update map" then renders that specific place** using those coordinates.
4. **Zoom in / zoom out BUTTONS** on the floating window — explicit clickable
   controls, not just trackpad pinch/scroll. The main canvas already has this
   exact pattern (`zoomControls` in `ContentView.swift` — a small `+`/`-`
   button stack overlaid on the map) — copy that pattern, don't invent a new one.

The user has been extremely clear and extremely frustrated that prior attempts
in the previous session did not deliver this. Do not re-litigate the design —
build exactly this, verify it actually works, and say plainly what you could
and couldn't verify.

## Critical environment constraint — read this before doing anything else

**Claude cannot see the user's screen and cannot click anything in the app.**

- There is no Accessibility permission (`osascript`/System Events UI scripting
  fails with "not allowed assistive access").
- `screencapture` *appears* to work (produces a real PNG) but **captures a
  different, disconnected session — not the user's actual monitor.** This was
  the single biggest wasted-time mistake of the previous session: trusting a
  screenshot that showed an empty desktop, concluding "no window exists," and
  reporting that as fact, when the user's real screen had the window right
  there the whole time. **Never present your own `screencapture` output as
  evidence of what the user sees. If you take one, treat it as meaningless.**
- The only reliable ground truth about the running app's actual UI is:
  1. Screenshots the **user** pastes into chat.
  2. Headless CLI verification flags exercising the real production code
     (`--verify-locator`, `--verify-locator-launch`, etc. — see below).
  3. Code review of the actual Swift.
- Because of this, **all interactive claims must be hedged honestly.** Fix
  what you can verify through code + headless checks, then ask the user to
  test the specific, narrow thing you couldn't verify yourself — don't imply
  you've confirmed something you haven't.

## What exists right now (state as of end of previous session)

- `App/HipparchusApp/FramePanel.swift` — defines `Locator` (an
  `NSViewRepresentable` wrapping `MKMapView`) and its `Coordinator`. Used both
  in the sidebar (`FramePanel`) and in a floating panel (see below). Also
  contains two CLI-driven verification functions:
  `verifyLocatorRegionConversion` and `verifyLocatorLaunchSequence`, plus
  `Sources/HipparchusGeometry/LocatorSync.swift` (a small, pure, **unit-tested**
  decision function — 6 tests in `Tests/HipparchusGeometryTests/LocatorSyncTests.swift`).
- `App/HipparchusApp/LocatorPanel.swift` — `LocatorPanelController`, an
  `NSPanel`-based floating window (`.floating` level, 700×560 default size),
  hosting the same `Locator` view. Opened via a toolbar button (map icon,
  `.primaryAction` placement, next to Export) in `ContentView.swift`, calling
  `locatorPanel.show(model: model)`.
- `App/HipparchusApp/MapModel.swift` — `browseWorldMap(to:)` sets the area
  from the locator; `didFinishLaunchSetup` flag (set true at the end of
  `startIfRequestedOnLaunch()`) distinguishes a restored session's area
  arriving late from a genuine live change (see "Bugs already fixed" below).

**None of this has been confirmed working by the user.** The last two things
the user actually saw (via their own screenshots) were: the sidebar map
rendering *something* (so MapKit itself works and isn't crashing), but not
zooming to "the whole world" as intended, and — critically — **the user says
the floating window's zoom/click/select still does not do what they asked
for**, largely because **what was built doesn't match what they asked for**:
the floating window currently only supports drag-to-pan and
pinch/scroll-to-zoom (inherited from the sidebar `Locator`), with no explicit
buttons, and clicking a *place* (as opposed to dragging the viewport) was
never implemented at all — there is no tap-to-select-a-point interaction, only
pan/zoom of the visible region.

## Bugs already found and fixed in the previous session (verified via headless checks — reuse this understanding, don't re-derive it)

1. **The Locator was embedded in the sidebar's `List`.** On macOS, `List` owns
   a real `NSScrollView`, which competes with `MKMapView`'s own pan/magnify
   recognizers for the same events. Fixed by moving it to a plain sibling
   `VStack` above the list. (Never confirmed by the user whether this alone
   fixed sidebar interactivity — it may or may not matter for the new
   floating-window-focused design below.)
2. **`.overlay { RoundedRectangle().strokeBorder(...) }` on top of the map**
   risked swallowing all hit-testing across its full frame (a stroked SwiftUI
   `Shape`'s hit-test area is its bounding box, not just the painted line).
   Fixed by moving the rounded-corner styling onto the `MKMapView`'s own
   `CALayer` (`view.layer?.cornerRadius`, etc.) instead of a SwiftUI overlay.
3. **A saved session's area, loaded asynchronously in `.task` after the
   window first appears, was defeating the "start at world scale" behavior**
   — it looked like a live user change and got synced to. Root-caused and
   fixed with `LocatorSync.decide(bbox:wasSettled:lastKnown:)`, a small pure
   function (tested) that distinguishes a late-arriving restored value from a
   genuine subsequent change. `MapModel.didFinishLaunchSetup` feeds it.
   **Confirmed via `--verify-locator-launch`,** which reproduces the exact
   launch sequence against the real `Coordinator`/`MKMapView` and prints each
   step — 0 spurious reports, matches design.
4. **MapKit has a hard, size-dependent maximum zoom-out limit.** A
   `MKCoordinateRegion` request of 170°×360° (or `MKMapRect.world` — tried
   both) gets silently clamped by MapKit to whatever it can actually render
   for the view's pixel size — confirmed empirically:
   - ~194×220pt view → clamped to ~72°×68°
   - ~420×340pt view → clamped to ~102°×148°
   - ~700×560pt view → gets much closer to a full recognizable globe
   This is why the floating panel was sized to 700×560 — a sidebar-sized
   locator physically cannot show "the whole world" recognizably, no matter
   what code asks for. This is a genuine MapKit constraint, not a bug to
   "fix" further — if the user wants a bigger view, make the window bigger,
   don't keep tweaking the region request.
5. Switched the world-scale request from a manually-guessed `MKCoordinateRegion`
   to `view.setVisibleMapRect(.world, animated: false)` — the correct,
   idiomatic way to ask MapKit for "as zoomed out as it goes," letting MapKit
   pick its own real maximum for whatever size the view ends up being.

Two headless verification flags exist and should keep passing (rerun after
any change):
```sh
Hipparchus.app/Contents/MacOS/Hipparchus --verify-locator-launch
Hipparchus.app/Contents/MacOS/Hipparchus --verify-locator 37.976,23.735,0.32,0.32
```

## Also watch out for: two copies of the app can coexist

`/Volumes/Hipparchus/Hipparchus.app` (an old DMG release, mounted) and
`/Applications/Hipparchus.app` (the one you rebuild) share the same bundle ID
and version string, so there's no visible way to tell them apart. Confirm
which one is actually running with:
```sh
ps aux | grep -i hipparchus | grep -v grep
```
and always relaunch by **explicit full path**, not `open -a Hipparchus` (name
resolution can pick the wrong one):
```sh
osascript -e 'tell application "Hipparchus" to quit' 2>/dev/null
pkill -f "/Applications/Hipparchus.app" 2>/dev/null
pkill -f "/Volumes/Hipparchus/Hipparchus.app" 2>/dev/null
open "/Applications/Hipparchus.app"
```
Rebuild via `bash Scripts/install-app.sh` (runs `xcodegen generate` + release
build + install to `/Applications`).

## What to actually build this session

Redesign the floating Locator window around what the user asked for — this is
a materially different interaction model from "drag the viewport," and it's
worth being honest that the previous session built the wrong thing:

1. **Explicit zoom in/out buttons** on the floating window, matching
   `ContentView.zoomControls`' existing look (small `+`/`-` button stack,
   `.regularMaterial` background, rounded rect border) — laid over the
   `MKMapView` the same way. These should drive `MKMapView` zoom via
   `setRegion`/`setCamera` with a zoom factor, exactly mirroring how
   `ViewportState.zoomed(by:)` works for the main canvas's buttons — reuse
   that pattern's shape, don't invent new zoom math.
2. **Click-to-select-a-point.** This is new: add a click gesture recognizer
   (`NSClickGestureRecognizer` or override `mouseDown(with:)` on a thin
   `MKMapView` subclass, or wrap with an `NSGestureRecognizer`) that converts
   the click point to a coordinate (`mapView.convert(_:toCoordinateFrom:)`),
   drops a marker/annotation there, and reports the coordinate outward —
   likely as a small bbox padded around the point (there's already a
   precedent: `CoordinateImport.parse`'s single-point handling in
   `Sources/HipparchusGeometry/CoordinateImport.swift` pads a bare point by
   `defaultPadDegrees = 0.05` — probably reuse that constant/idea rather than
   inventing a new pad size).
3. **Wire the reported coordinate through to "Update map" already fetching
   it.** This part likely already works via the existing
   `onRegionChanged`/`browseWorldMap(to:)` plumbing (a bbox set by the locator
   already becomes `model.bbox`, and "Update map" already fetches
   `model.bbox`) — confirm this rather than rebuilding it; the missing piece
   is specifically *producing* a bbox from a click, not the pipe from bbox to
   fetch.
4. Decide whether pan/zoom-by-drag stays alongside the new click-to-select
   and explicit buttons, or whether click-to-select should coexist cleanly
   with drag-to-pan (likely fine: a `NSClickGestureRecognizer` and
   `MKMapView`'s built-in pan don't inherently conflict, since a click is a
   very-short/no-movement gesture — but verify there's no accidental
   "every drag also drops a marker at the start point" bug).

## How to verify before telling the user anything works

Since you cannot see the screen or click anything:
- Extend the existing headless verification pattern
  (`verifyLocatorRegionConversion`, `verifyLocatorLaunchSequence` in
  `FramePanel.swift`) with a new function that drives the click-to-coordinate
  conversion directly against a real `MKMapView` with a known region and a
  known click point in view coordinates, asserting the resulting coordinate
  is what it should be. This is the same trick already used throughout this
  codebase for "nobody can screenshot this" verification (`--search`,
  `--import-clipboard`, `--verify-zoom-then-update` all follow this pattern —
  read `MapModel.startIfRequestedOnLaunch()` for the full list and copy the
  house style).
- Run the full package test suite (`swift test`, currently 662 tests) after
  any change to `Sources/`.
- For the zoom buttons specifically, you can verify the *math* headlessly
  (does pressing zoom-in produce a smaller, correctly-centered region?) but
  **not** that a real click on a real button in a real window does anything —
  say so explicitly when reporting back, and ask the user to confirm the
  visual/interactive part specifically, narrowly, rather than a vague "does
  it work now?"
- Before asking the user to test, rebuild + reinstall
  (`bash Scripts/install-app.sh`) and relaunch by explicit path as above.

## Tone/process note for this session

The user does not want another round of "I fixed X, please try it and tell
me" followed by it still being broken. Before reporting anything as fixed:
read the actual code path end to end, verify everything headlessly that can
be verified headlessly, and be explicit and narrow about the one or two
things that genuinely require the user's own eyes/hands — don't ask them to
re-verify things you could have checked yourself.
