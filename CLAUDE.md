# Working on HipparchusMac

## The UI tests take over the machine

`App/HipparchusUITests/` is XCUITest. It does **not** click "inside" the app the
way a unit test calls a function — it synthesises **real system-level mouse and
keyboard events**, calls `app.activate()` to pull focus, and types keys. Whatever
you are doing on this Mac at the time, it is doing it to that too.

**Never run `Scripts/ui-test.sh` or `xcodebuild test -scheme HipparchusUITests`
without asking for that specific run, every time.** And never run it twice in a
row: each run is a whole application plus `xcodebuild`, and several back to back
is what invites the OOM killer onto everything else that is open. Runs have died
with exit 137 under memory pressure, each leaving an orphaned `Hipparchus.app`
holding focus. After any killed run, check `pgrep -lf Hipparchus.app` and kill
what survived.

The suite is also **environment-sensitive in a way that looks like a code
failure**. It has failed three isolated re-runs with "Render map exists but
cannot be clicked" for no reason other than **Mission Control being open** —
every window is a thumbnail there, so nothing is hittable. Before believing a red
board, open the failure recording in the `.xcresult`.

"Open the app and check X" authorises **one** launch, looked at. Not a suite.

## What to run instead

All of these are headless and open nothing:

```sh
swift build                 # the libraries and the CLI
swift test -c release       # 1070 tests, about two seconds
swift test                  # the same, about a minute
```

**Run the suite in release.** Contouring is a tight numeric loop over a grid and
the unoptimised build runs it roughly fifty times slower. Debug is worth it only
when you need a debugger.

To see a render, use the CLI and look at the PNG it writes — do not launch the
app, and do not build a composite image:

```sh
.build/release/hipparchus-cli --bbox 32.27,34.56,34.59,35.69 \
    --preset "Clean Atlas" --out /tmp/plate
```

Run it **once at a time**, not in a loop. A world sheet at export quality leaves
a 239 MB SVG beside an 86 MB PDF.

## Two files are generated. Do not edit them by hand

- **`Sources/HipparchusRender/PresetTables.swift`** comes from the Python's
  preset registry via `Scripts/generate-presets.py`. Five hundred lines of colour
  data transcribed by hand would be five hundred chances to mistype a channel.
  Change the Python, re-run the generator, commit the result.
  `--check` says whether it is stale and writes nothing.
- **`App/HipparchusMac.xcodeproj`** comes from `App/project.yml` via xcodegen and
  is git-ignored. Edit the spec.

The test count in `README.md` is derived too, from `swift test --list-tests`:
`Scripts/update-test-count.sh`, with `--check` to ask whether it is stale. It
went wrong three times in one day before it was derived, and a figure that is
wrong more often than it is right teaches a reader that the numbers here are
decorative — when most of them are the whole argument.

## This repository has a twin

`~/AI/ClaudeCode/Hipparchus` is the Python application. The two are **upstream of
each other in different places**: presets and the contour, band and field maths
flow from the Python; palettes, hillshade, line weight, the page model and the
whole marine layer were written here and ported back.

**A substantive change on one side owes a counterpart on the other**, and saying
which parts were ported, which already existed, and which were deliberately not
is part of finishing. Some divergences are documented on purpose — the Python
draws the sea *over* the relief, which is what keeps the Waitematā visible — and
those must not be "fixed".

The thing to know about the parity fixtures: **each is generated from the
implementation it checks.** `palette-parity.json` here compares this engine
against `Scripts/build-style-packs.py` beside it, and the Python's compares its
module against itself. They catch a change nobody meant to make; they do not
catch the two applications drifting apart. Where that matters, the values are
pinned as literals in both suites, each naming the other — see
`PaletteTests.testTheMarineLayerMatchesThePythonApplication` and
`DerivedStyleTests.testTheDerivedWeightsMatchThePythonApplication`.

One rounding trap, learned twice: Python's `round()` is half-to-even. Both
`Palette.mix` and `RGBAColor.mixed(towards:)` round `.toNearestOrEven` to match
it. Swift's default `.rounded()` is half-away-from-zero and puts a channel one
unit out, which no fixture will catch.

## The window is not covered by anything

The model behind the window is verified continuously and the window is not: **no
automated check covers the layout**, so a control that moves, greys out or stops
responding will not fail anything. Anything decidable without a widget belongs in
`Sources/` and is tested there. A rule kept in view code can only be checked by a
person opening the panel and looking at it.

## The working files

The plans, briefs and handoffs this project is built from live in `documents/`
and `docs not to push/`, both deliberately outside the repository. They name
paths on one machine and read as instructions to whoever picks the work up next.
`README.md` is the document for anyone else.
