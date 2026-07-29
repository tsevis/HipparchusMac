# HipparchusMac

A native macOS rewrite of [Hipparchus](../Hipparchus): choose an area of the
world, fetch map data from public sources, and export layered,
Illustrator-editable SVG.

The Python application is the specification. It is finished, it works, and its
454 tests are an executable description of the behaviour being ported. Anything
here that disagrees with it is a bug here.

**Status: first slice, in progress.** One vertical path is being built end to
end — terrain tiles → contours and elevation bands → Core Graphics canvas → SVG
— before any other source, the source-stack interface or the style presets are
touched. See `KICKOFF.md` for the brief and the design it is being built to.

## Requirements

- macOS 15 or later
- Xcode 26 / Swift 6.2
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), to
  generate the app project
- CMake, **only** if you want to rebuild GEOS. The library is committed.

## Building

```sh
swift build                 # the libraries and the CLI
swift test                  # every test; no network, no fixtures on disk
```

The app project is generated rather than committed, so `project.yml` is the
source of truth and there is no `.xcodeproj` to merge:

```sh
xcodegen generate --spec App/project.yml
open HipparchusMac.xcodeproj
```

## Layout

```
Sources/HipparchusGeometry   contours, Web Mercator, the sample grid — pure arithmetic
Sources/HipparchusGEOS       the GEOS bridge, and the geometry that needs an engine
Sources/HipparchusData       provider contracts, terrain tiles, terrarium decoding
Sources/HipparchusRender     render models, the Core Graphics canvas, SVG and PDF export
Sources/hipparchus-cli       headless fetch → render → export, for checking real output
App/                         project.yml and the SwiftUI views, which hold no logic
Vendor/geos                  the committed GEOS xcframework — see Docs/GEOS.md
```

The targets form a strict chain, `HipparchusGeometry ← HipparchusGEOS ←
HipparchusData ← HipparchusRender`. The Python had an import cycle between its
data layer and its application layer that no test caught, because every test
reached the application layer first. Separate targets make the same mistake a
compile error.

## Verifying output

Rendering is visual, so the checks are numbers rather than impressions. These
areas have known answers:

| Area | Bounding box | Expect |
|---|---|---|
| Santorini | `25.32, 36.33 → 25.50, 36.48` | −79 m caldera floor, 525 m rim |
| Athens | `23.575, 37.816 → 23.895, 38.136` | −4 m to 1091 m |
| San Francisco | `−122.53, 37.70 → −122.35, 37.84` | tops at 284 m |
| Addis Ababa | `38.65, 8.90 → 38.88, 9.10` | never below 2,075 m |
| Everest | `86.85, 27.93 → 87.05, 28.06` | 5,060 m to 8,746 m |
| Myrtoan Sea | `23.2, 36.3 → 24.2, 37.1` | reaches −1,310 m |

A coastal strip should yield no bathymetry, and open water should yield no
summits.

## Things that are not bugs

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
