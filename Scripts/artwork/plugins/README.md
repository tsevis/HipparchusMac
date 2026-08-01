# Artwork presets

Two plugin manifests that exist to draw the application's own pictures — the
splash screen's Cyprus, and the app icon's Cape Paphos — and for nothing else.

They live here rather than in the app's plugin folder on purpose. A plugin
installed there appears in **All styles** alongside the sixteen real presets,
which is wrong twice over: nobody wants to draw a map in "Turquoise Sea Bold",
and a `--render-to` run used to write whichever preset it was given into the
session, so a single artwork render left the app reopening on a turquoise map
of nowhere the person had chosen. The app no longer saves the session on a
batch run, but these still do not belong in a style list.

To regenerate the artwork, install one temporarily:

```bash
PLUGINS=~/Library/Containers/com.hipparchus.HipparchusMac/Data/Library/Application\ Support/Hipparchus/Plugins
mkdir -p "$PLUGINS/artwork" && cp Scripts/artwork/plugins/icon-artwork.json "$PLUGINS/artwork/plugin.json"

Hipparchus.app/Contents/MacOS/Hipparchus \
  --bbox 32.375,34.735,32.445,34.790 --preset "Turquoise Sea" \
  --sources terrain_tiles --render-to cape-thin.png

rm -rf "$PLUGINS/artwork"
```

The render lands in the app's sandboxed Documents folder. Copy it to
`Scripts/artwork/` under the name the build script expects, then run
`Scripts/build-app-icon.py` or `Scripts/crop-about-artwork.py`.

| Manifest | Presets | Draws |
|---|---|---|
| `icon-artwork.json` | `Turquoise Sea`, `Turquoise Sea Bold` | Cape Paphos for the app icon, thin and bold |
| `cyprus-backdrop.json` | `Pale Sea` | Cyprus for the About window |

Both paint white lines over a flat ground and switch nearly everything else
off — roads, buildings, labels, thirty-odd layers — because an icon at 32
points and a backdrop behind white type both want a drawing, not a map.
