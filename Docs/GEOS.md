# GEOS

## Why it is here

The Python this port follows uses Shapely, which is a binding to GEOS. Shapely is
not a geometry implementation — GEOS is. Reimplementing planar geometry in Swift
would mean reimplementing robust polygon clipping, noding and overlay, which is a
research project rather than a port, and it would give *different answers* at the
seams. Linking the same engine means the ported pipeline agrees with the
original.

The surface used is small and entirely within the GEOS C API:

| Used for | GEOS C API |
|---|---|
| Cutting closed contour rings into faces | `GEOSPolygonize` |
| Dissolving faces, merging layers | `GEOSUnaryUnion`, `GEOSUnion` |
| Clipping to the frame, banding | `GEOSIntersection`, `GEOSDifference` |
| Repairing self-intersections | `GEOSBufferWithStyle` (distance 0) |
| Deciding whether a face is above a level | `GEOSPointOnSurface` |
| Thinning linework | `GEOSTopologyPreserveSimplify`, `GEOSSimplify` |
| Validity, emptiness, area, distance | `GEOSisValid`, `GEOSisEmpty`, `GEOSArea`, `GEOSDistance` |
| Label placement along a line | `GEOSInterpolate` |
| Spatial index for pairwise work | `GEOSSTRtree_*` |
| Derived layers, replacing SciPy | `GEOSVoronoiDiagram`, `GEOSDelaunayTriangulation` |

`GEOSPointOnSurface` is the load-bearing one. Elevation bands keep a polygonized
face only if the elevation field sampled at that point is genuinely at or above
the level, so containment is *measured* rather than inferred from ring nesting.
Holes, islands in holes and nesting to any depth then fall out for free.

## What is committed, and why

`Vendor/geos/geos.xcframework` — one macOS slice, universal arm64 + x86_64, a
single static library, about 17 MB. It is committed on purpose: a clean clone
builds with no CMake installed and no network access. `Vendor/geos/MANIFEST.txt`
records the version, the archive's sha256, every CMake flag and the toolchain
that produced it.

## Rebuilding

```sh
Scripts/build-geos-xcframework.sh          # no-op if the framework is present
Scripts/build-geos-xcframework.sh --force  # rebuild
```

The script is reproducible by construction rather than by hope: the version and
its sha256 are literals in the script, the archive is verified before it is
unpacked, and every flag that affects the output is written there rather than
inherited from the environment. It refuses to build from an archive whose hash
does not match.

To move to a new GEOS: change `GEOS_VERSION`, replace `GEOS_SHA256` with the
hash of the new archive, run with `--force`, and run `swift test`. The bridge
tests assert the linked version, so a bump that is not intended will fail rather
than pass quietly.

## How it is wired

- `libgeos.a` and `libgeos_c.a` are merged with `libtool -static` into one
  archive. An XCFramework carries a single library, and a consumer linking only
  the C API would fail on every C++ symbol behind it.
- The staged headers are `geos_c.h` (generated from `geos_c.h.in` at configure
  time, so it comes from the build tree) plus `geos/export.h`, which `geos_c.h`
  includes for its visibility macro. That is the only C++ header exposed.
- A hand-written `module.modulemap` declares `module CGEOS`, which is what
  `import CGEOS` resolves to.
- `HipparchusGEOS` carries `.linkedLibrary("c++")`, because GEOS is C++ behind a
  C interface and the runtime has to come along.

If a future SwiftPM release stops accepting a static-library XCFramework, the
fallback is a dynamic `geos.framework` embedded in the app bundle. That is a
change to make deliberately, not to slide into.

## Memory and threading

`GEOSContext` is deliberately **not** `Sendable`. A GEOS reentrant context
carries mutable error state and its own allocator; using one from two threads at
once corrupts both. Making the type non-sendable means Swift refuses to let it
cross a concurrency boundary rather than letting it crash at runtime. Code that
needs GEOS on another task creates its own context, which is cheap.

Ownership rules that bite, handled in `GEOSConversion.swift`:

- `GEOSGeom_createPolygon` and `GEOSGeom_createCollection` **take ownership** of
  their parts. `ManagedGeometry.release()` exists for exactly this: it hands the
  pointer over without double-freeing. On failure ownership never transferred, so
  the parts are freed by hand.
- `GEOSGetExteriorRing`, `GEOSGetInteriorRingN`, `GEOSGetGeometryN` and
  `GEOSGeom_getCoordSeq` return **borrowed** pointers. Destroying one frees part
  of a geometry GEOS still owns.
- `GEOSPolygonize` borrows its inputs, so the caller keeps owning them.

## Licence

GEOS is LGPL-2.1. Static linking is permitted on the condition that the object
files and the build recipe are available to anyone who receives the binary. Both
are in this repository: `Vendor/geos/geos.xcframework` and
`Scripts/build-geos-xcframework.sh`.
