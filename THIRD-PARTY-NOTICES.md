# Third-party notices

Hipparchus is [MIT-licensed](LICENSE). That covers the code in this repository
and nothing else. Two other categories of thing arrive with the application and
carry their own terms: **one linked library**, and **the map data the app
fetches**. This file records both.

The data list here is not maintained by hand. It is the same registry the
application itself reads — `Sources/HipparchusData/Attribution.swift` — which a
test holds to completeness: every shipped source either carries a credit or is
explicitly declared exempt, with a reason. A source added without one fails the
suite. What follows is that registry in prose.

## The one that has obligations: GEOS

**GEOS 3.14.1 — LGPL-2.1 — <https://libgeos.org/>**

Every polygon operation in this app is GEOS: the band builder's `polygonize`,
`unaryUnion`, `difference` and `pointOnSurface`, the coastline noding, the sea
inference, the smoothing. It is not an optional extra, and it is **not MIT**.

It is linked **statically**, as a universal `libgeos.a` in
`Vendor/geos/geos.xcframework`. Static linking of an LGPL library is permitted,
on the condition that anyone who receives the binary can relink the application
against their own version of GEOS. This repository satisfies that:

- **The exact upstream source is pinned and verifiable.** `Scripts/build-geos-xcframework.sh`
  names the release, its URL, and its sha256, and refuses to build from an
  archive that does not match:

  ```text
  source   https://download.osgeo.org/geos/geos-3.14.1.tar.bz2
  sha256   3c20919cda9a505db07b5216baa980bacdaa0702da715b43f176fb07eff7e716
  ```

- **The build is reproducible.** Every CMake flag that affects the output is a
  literal in that script rather than inherited from the environment, and the
  flags actually used are recorded in `Vendor/geos/MANIFEST.txt` beside the
  artefact.

- **The application's own source is here, under MIT.** Relinking against a
  modified GEOS needs no permission and no object-file drop: replace the
  xcframework, or re-run the build script against a different release, and
  rebuild.

**If you redistribute a built copy of this app**, that obligation travels with
it. Ship it with a pointer to this repository, or carry the equivalent of the
three points above yourself. Removing GEOS is not an option — there is no
fallback path.

## The other tool credit

**Apple MapKit — per Apple's terms — <https://developer.apple.com/maps/>**

Used for geocoding and for the Locator's basemap. Basemap imagery is © Apple and
is shown in the app, never exported into a sheet.

## Map data

None of these are vendored. They are fetched at run time from public endpoints,
and each exported sheet carries the sources that actually drew it — so a file's
credits describe that file rather than the application in general.

| Source | Terms | Credit line |
| --- | --- | --- |
| [OpenStreetMap](https://www.openstreetmap.org/copyright) | Open Database License (ODbL) | Map data © OpenStreetMap contributors |
| [Mapzen / AWS Terrain Tiles](https://registry.opendata.aws/terrain-tiles/) | public domain and ODbL, by tile source | Elevation from Mapzen / AWS Terrain Tiles |
| [EMODnet Bathymetry](https://emodnet.ec.europa.eu/en/bathymetry) | free to use with attribution | Bathymetry in European seas from EMODnet Bathymetry |
| [NOAA CoastWatch ERDDAP](https://coastwatch.pfeg.noaa.gov/erddap/) | public domain (U.S. Government work) | Sea surface temperature from NASA JPL MUR, served by NOAA CoastWatch ERDDAP |
| [NOAA CoastWatch ERDDAP](https://coastwatch.pfeg.noaa.gov/erddap/) | public domain (U.S. Government work) | Geostrophic surface currents from NOAA/NESDIS sea surface height |
| [NASA GIBS](https://nasa-gibs.github.io/gibs-api-docs/) | free to use with attribution | Imagery from NASA Global Imagery Browse Services (GIBS) |
| [USGS](https://earthquake.usgs.gov/) | public domain (U.S. Government work) | Earthquakes from the U.S. Geological Survey |
| [CelesTrak](https://celestrak.org/) | free to use with attribution | Satellite orbital elements from CelesTrak |
| [Nominatim](https://www.openstreetmap.org/copyright) | ODbL, per OpenStreetMap's terms | Geocoding by Nominatim |

**ODbL is share-alike.** If you publish a map made from OpenStreetMap data —
including one exported from this app — you must credit OpenStreetMap
contributors, and if you publish a derived *database* you must license it under
ODbL too. A rendered picture is a Produced Work and only owes the credit; the
GeoJSON export is closer to a database, so treat it accordingly.

## Sources that owe nothing, and why

Recorded so that "no attribution" reads as a decision rather than an oversight.
This list is `Attribution.exempt` in the same file, and the completeness test
requires a source to be in one list or the other.

| Source | Why nothing is owed |
| --- | --- |
| Simulated terrain | This application's own arithmetic. Not a measurement of anywhere. |
| A local `.osm.pbf` | The user's own file. |
| Local vector tiles | The user's own file. |
| [Natural Earth](https://www.naturalearthdata.com/) | Public domain, and its own terms explicitly waive attribution. Credit it anyway if you like — it is good manners and they ask for none. |
| Overture Maps | The user's own file, from a distribution with its own terms at source. |

## Not for navigation

Any sheet carrying depths, sea marks or currents states that it is not a charted
survey and is not corrected by Notices to Mariners. That notice is on by default,
and the machine-readable claim survives even when the words are switched off. It
is a safety statement rather than a licence one, but it travels with the same
data, so it is recorded here too.
