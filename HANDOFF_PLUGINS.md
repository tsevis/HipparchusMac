# Handoff: style packs and what else a plugin could be

Paste this whole file as the opening message of a new session.

---

## What this is

`/Users/tsevis/AI/ClaudeCode/HipparchusMac` — a native macOS port of a
finished Python application at `/Users/tsevis/AI/ClaudeCode/Hipparchus`. Read
`README.md` and `KICKOFF.md` first; the Python is the specification.

`main` is at `0cc065d`, clean, in sync with
`github.com/tsevis/HipparchusMac`. **686 tests, 0 failures** (`swift test`).

## Read this before touching anything

**You cannot see the user's screen, and you cannot click anything.**

- No Accessibility permission: `osascript` UI scripting fails.
- `screencapture` *appears* to work but captures a different, disconnected
  session. It once produced a convincing empty desktop and sent an entire
  session down the wrong path. **Never present your own screenshot as
  evidence of what the user sees.** If you take one, treat it as meaningless.
- Ground truth is: screenshots the *user* pastes, headless CLI verification
  against real production code, and reading the Swift.
- Hedge interactive claims honestly. Verify everything verifiable headlessly,
  then ask the user to check the one narrow thing you could not.

**Other traps, all of which have already cost time:**

- Several copies of the app can exist. Confirm with
  `ps aux | grep -i hipparchus`, always launch by full path
  (`open "/Applications/Hipparchus.app"`), and never trust `open -a`.
  Xcode DerivedData holds stale builds too.
- The Locator panel's title bar shows the binary's build timestamp
  (`Locator — build 1 Aug 17:43`). Use it to confirm which build is running.
- **A second Claude session has been working in this repo.** It committed and
  pushed between a `git diff` and a `git add` once. Check `git log` and
  `git status` before committing; consider a branch.
- Rebuild and install with `bash Scripts/install-app.sh`.

## What a plugin is here

`Sources/HipparchusRender/Plugins.swift`. A plugin is a folder in the app's
plugin directory containing `plugin.json`; it contributes **presets**, in the
same format `PresetStore` writes, so a saved style can be shared by copying a
folder. `PluginLoader` gives fault isolation — one broken plugin costs exactly
itself and is named in `loadErrors`, shown in the sidebar under Plugins.

**One deliberate divergence from the Python:** there, a plugin is a Python
module imported at runtime. A sandboxed, hardened-runtime macOS app cannot do
that — library validation refuses code not signed by the same team. So *user*
plugins are declarative and *built-in* plugins are Swift types conforming to
`Plugin`. Little is lost: the Python's protocol has one implementation and its
`register()` returns `None`.

```
~/Library/Containers/com.hipparchus.HipparchusMac/Data/Library/Application Support/Hipparchus/Plugins/
```

Reachable from **Style → Plugins → Show plugins folder**.

## What exists now

- `Plugins/tsevis-palette/plugin.json` — **Tsevis Daylight** and **Tsevis
  Nocturne**, built from the app's turquoise `#1AAFA5` and the logo's blue
  `#3761A0`. All 37 layers are *derived* from those two by mixing rather than
  chosen individually, which is why they hold together.
- `Scripts/artwork/plugins/` — two manifests that exist only to draw the app
  icon and the About window's Cyprus. Deliberately **not** installed: they
  would appear as styles, and nobody wants to draw a map in "Turquoise Sea
  Bold". `Scripts/artwork/plugins/README.md` explains installing them
  temporarily.

## Checking a style

By rendering it and looking, never by reasoning about the numbers:

```bash
Hipparchus.app/Contents/MacOS/Hipparchus \
  --bbox 4.86,52.355,4.94,52.395 --preset "Tsevis Daylight" \
  --sources terrain_tiles --render-to day.png
```

Output lands in the app's sandboxed `Documents`. Read the PNG back and look
at it — that is the only way to judge a style.

## What shipped

All five items from the first version of this handoff are done.

- `Scripts/build-style-packs.py` generates every pack. Each preset *derives*
  all thirty-seven layer styles from a handful of named colours rather than
  choosing them one by one — a palette picked layer by layer drifts, and one
  derived by mixing cannot. Change a colour, re-run, reinstall.
- **Tsevis Palette** — Daylight and Nocturne, plus five Ionian islands, which
  is what proves a plugin can carry places as well as styles.
- **Nautical** — Admiralty Chart. The inversion of every other preset: the sea
  carries the information, the land is what is left over.
- **Duotone Press** — two riso pairs. Nothing is a shade of anything; every
  colour is one of the two inks or one of them let down toward the paper.
- **High Contrast** — light and dark, built for legibility rather than taste.
  Roads at 1.8×, and the fills that make a map pretty deleted, because they
  are what reduce contrast between the things that matter.

Daylight's first version read turquoise rather than blue, because the
vegetation was tinted toward turquoise and a green city then swamped it. The
vegetation is a desaturated blue-green now, so the two brand colours are the
only saturated things on the sheet.

## What is still open

- Nothing in the plugin system itself. `PluginRegistry` carries presets and
  places; anything further is a new capability rather than a gap.
- The packs have been rendered over Amsterdam and nowhere else. A style that
  works on canals may not work on a mountain or a desert — Everest, Hawaii and
  the Dominican Republic are in the saved places for exactly this.
- Nobody has seen any of them in the window, only as PNGs.

## How to verify anything here

The house pattern is headless flags driving production code, because nobody
can screenshot this. Existing ones worth knowing:

```bash
--plugins                     # every style, where it came from, what refused to load
--verify-locator-click        # a click resolves to the place under it
--verify-locator-drag         # a dragged rectangle is the ground it covered
--verify-locator-fetch L,L    # what the Locator shows is what Render map draws
--verify-fills-window ASPECT  # the drawn map fills the window
--bbox … --preset … --render-to out.png
```

Run `swift test` after touching `Sources/`. **A run started with any of these
flags no longer saves the session** — that was a real bug: every artwork
render used to write its own preset into the user's session, and the app kept
reopening on a turquoise map of nowhere they had chosen.

## Tone

The user does not want "I fixed X, please try it". Read the code path end to
end, verify everything verifiable, and be explicit and narrow about the one or
two things that genuinely need their eyes. When something is a judgment call —
especially a destructive or spec-diverging one — ask before doing it.
