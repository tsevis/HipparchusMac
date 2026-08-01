# Handoff: Hipparchus as something you would hang on a wall

Paste this whole file as the opening message of a new session.

---

## What this is

`/Users/tsevis/AI/ClaudeCode/HipparchusMac` — a native macOS port of a
finished Python application at `/Users/tsevis/AI/ClaudeCode/Hipparchus`. Read
`README.md` and `KICKOFF.md` first; the Python is the specification, and every
departure from it in this port is deliberate and written down.

`main` is at `873e18f`, clean, in sync with `github.com/tsevis/HipparchusMac`.
**690 tests, 0 failures** (`swift test`).

## Read this before touching anything

**You cannot see the user's screen, and you cannot click anything.**

- No Accessibility permission: `osascript` UI scripting fails.
- `screencapture` *appears* to work but captures a different, disconnected
  session. It once produced a convincing empty desktop and sent an entire
  session down the wrong path. **Never present your own screenshot as
  evidence of what the user sees.** If you take one, treat it as meaningless.
- Ground truth is: screenshots the *user* pastes, headless CLI flags driving
  real production code, and reading the Swift.
- **You can look at what the app draws.** `--render-to out.png` writes into
  the app's sandboxed `Documents`; read the PNG back with the Read tool and
  actually look at it. That is the only honest way to judge a style, and it
  has caught things reasoning did not.

**Traps that have already cost hours:**

- Several copies of the app can exist. Confirm with
  `ps aux | grep -i hipparchus`, launch by full path
  (`open "/Applications/Hipparchus.app"`), never `open -a`. Xcode DerivedData
  holds stale builds too. The Locator's title bar shows the binary's build
  time — use it to confirm which build is running.
- **A second Claude session has worked in this repo** and once pushed between
  a `git diff` and a `git add`. Check `git log` and `git status` before
  committing.
- Rebuild and install with `bash Scripts/install-app.sh`.
- Input bugs are real here: a Wacom pen's clicks were being discarded because
  `NSClickGestureRecognizer` treats any movement as a drag. If something works
  with a mouse and not a pen, that is why.

## The direction

The user pointed at **https://www.cartoart.net** — a free web tool that turns
a place into wall art. What it advertises: ten named styles, "80+ colour
palettes", layer toggles with adjustable line weights, 3D terrain with
vertical exaggeration and sun angle, and export at **24×36 inches, 300 DPI**
(7,200 × 10,800 px), watermark-free.

That is read off their marketing page, not their code. The point is not to
copy the list. Hipparchus already does most of it, and does the serious part —
real measured data with provenance carried into the file — better. What the
comparison usefully exposes is where this app stops short of being something
you would print and frame.

**Verified against our code, not assumed:**

| Their capability | Where Hipparchus actually stands |
|---|---|
| Export 24×36 in @ 300 DPI | **Gap.** `exportPNG` is hardcoded `CGSize(2400, 1800)`. SVG has paper presets and orientation in `CompositionPanel`; PNG and PDF have no physical size at all. |
| 3D terrain, sun angle, exaggeration | **Half.** `LayerStyle` already carries `illumination`, `illuminationAzimuth`, `illuminationBands`, lit/shadow scales, and `Illumination.swift` implements it — but per-layer and per-preset, with no live control. |
| Hillshade | **Gap, and a real one.** `TerrainLayer.hillshade` exists in the draw order and in `FileLayer.all`, but `TerrainTileProvider` says plainly: "No provider computes a hillshade; the layer exists for file sources." The provider already has the elevation grid. This is the highest visual payoff on the list. |
| 80+ palettes | **Different shape.** We have 16 built-in presets plus plugin packs, where a preset is a whole sheet. A *palette* — recolour without restyling — is a separate axis we do not have. |
| Layer toggles, line weights | **Toggles yes** (`LayersPanel`), **weights no**: stroke widths are per-preset, not adjustable live. A single global weight scale would be a small knob with a large effect. |

## Suggested work, in the order I would do it

1. **Hillshade from the elevation grid we already fetch.** `TerrainTileProvider`
   builds a `Field2D` of elevations; a standard hillshade is a slope/aspect
   calculation over it against a sun azimuth and altitude. It fills a layer
   that already exists everywhere in the pipeline — draw order, layer
   inventory, every preset's style table — so nothing downstream needs
   inventing. Test it the way `Illumination` and `Contours` are tested, with a
   parity fixture; there are four such fixtures already (`Scripts/generate-*-parity-fixture.py`).

2. **Export at a real size.** A paper size and a DPI, applied to PNG and PDF
   as they already are to SVG. `SVGExporter.Composition` has `paper_preset`
   and `orientation`; the work is extending that to the other two exporters
   and putting the controls where the Export menu is. Beware: a 7,200 × 10,800
   render is 78 megapixels — check memory and time before promising it, and
   say honestly what it costs.

3. **A live line-weight scale.** One multiplier over every stroke width,
   beside Quality in the Style panel. Cheap, and it is the difference between
   a screen map and a print.

4. **Palettes as a separate axis from presets.** Recolour a sheet without
   restyling it. `Scripts/build-style-packs.py` already derives all 37 layer
   styles from a handful of named colours — that function *is* a palette
   engine, it just runs at build time. Moving it into the app would make
   "any style in any palette" real rather than combinatorial.

5. **Sun angle and exaggeration as controls**, once (1) exists — they are the
   knobs a hillshade wants, and the illumination fields are already there.

## What a plugin is here

`Sources/HipparchusRender/Plugins.swift`. A folder with a `plugin.json`,
contributing **presets** (in the same format `PresetStore` writes) and
**places**. `PluginLoader` gives fault isolation: one broken plugin costs
exactly itself and is named in `loadErrors`, shown under Style → Plugins.

Four packs live in `Plugins/`, generated by `Scripts/build-style-packs.py`:
Tsevis Palette (+ five Ionian islands), Nautical, Duotone Press, High
Contrast. Install by copying into the app's plugin folder — the button under
Style → Plugins reveals it.

`Scripts/artwork/plugins/` holds two manifests that exist only to draw the app
icon and the About window's Cyprus. Deliberately not installed: they would
appear as pickable styles.

**One deliberate divergence from the Python:** there a plugin is a Python
module imported at runtime. A sandboxed, hardened-runtime app cannot do that —
library validation refuses code not signed by the same team — so user plugins
are declarative and built-in plugins are Swift types. Little is lost; the
Python's protocol has one implementation whose `register()` returns `None`.

## Verifying anything

The house pattern is headless flags driving production code:

```bash
--plugins                     # every style and place, where each came from, what refused
--verify-locator-click        # a click resolves to the place under it
--verify-locator-drag         # a dragged rectangle is the ground it covered
--verify-locator-fetch L,L    # what the Locator shows is what Render map draws
--verify-fills-window ASPECT  # the drawn map fills the window it is in
--verify-file-access PATH     # a chosen file survives a relaunch
--bbox … --preset … --render-to out.png
```

Run `swift test` after touching `Sources/`. A run started with any of those
flags **does not save the session** — that was a real bug: artwork renders
were writing their own preset into the user's session, and the app kept
reopening on a style of nowhere they had chosen.

## Known open items

- The four style packs have been rendered over Amsterdam and nowhere else. A
  style that works on canals may not work on a mountain — Everest, Hawaii and
  the Dominican Republic are in the saved places for exactly that.
- Nobody has seen the packs, the About window, the app icon at Dock size, or
  the 4×4 style grid in the actual window. Only as PNGs.
- `⌘1`–`⌘9` reaches only the first nine of sixteen saved places.
- Hawaii and the Dominican Republic are large enough that Overpass declines
  them; terrain renders fine. That is correct behaviour, not a bug.

## Tone

The user does not want "I fixed X, please try it" followed by it still being
broken. Read the path end to end, verify everything verifiable, look at what
you rendered, and be narrow and explicit about the one or two things that
genuinely need their eyes. When something is destructive or diverges from the
Python, ask first.
