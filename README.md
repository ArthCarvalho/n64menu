# m64menu

A flashcart menu for the Nintendo 64, restyled around the ModRetro M64's interface
design. It supports SummerCart64 and 64drive.

## Relationship to n64menu

**m64menu is a fork of [ArthCarvalho/n64menu](https://github.com/ArthCarvalho/n64menu).**
It was renamed to avoid implying it is the same project, because it has diverged in
both appearance and tooling. Upstream remains the origin of the menu engine, the
flashcart backends and the boot path.

What this fork adds:

- a presentation modelled on the M64's own menus: an inset cover grid with real
  gutters, dimmed unselected art, a marker-based selection, a skewed navigation
  ribbon and a typographic header;
- cartridge save support driven by a per-title sidecar (see below);
- a Windows-native build that needs no WSL or Docker;
- `m64importer`, a cross-platform Sokol desktop tool that prepares ROMs and box art
  for the SD card. The original PowerShell importer remains available for scripted
  Windows workflows.

### Naming

The ROM installed on the SD card must be called `sc64menu.n64`. That name is
required by the SummerCart64 firmware, which looks for it at the card root, so it
is deliberately *not* renamed to match the project.

## Licensing

This project is licensed under the MIT License; see [LICENSE](LICENSE). Upstream
adopted MIT in [ArthCarvalho/n64menu#8](https://github.com/ArthCarvalho/n64menu/pull/8),
and this fork inherits it. The copyright notice names both holders and must be
preserved in redistributions.

Third-party material is tracked separately:

- `tools/fonts/PressStart2P-Regular.ttf` is licensed under the SIL Open Font
  License 1.1, included as `tools/fonts/OFL.txt`.
- `tools/logo/sc64_logo.png` is the mark rendered by the menu. It is vendored
  rather than downloaded, so the build makes no network request for artwork.
- The menu is styled after the ModRetro M64 interface but ships none of its
  artwork. No affiliation with or endorsement by ModRetro or SummerCart64 is
  claimed, and the MIT License does not grant trademark rights.
- This fork generates every asset it ships. It contains no data extracted from
  commercial ROMs.

## SD card layout

Install `sc64menu.n64` at the root of the SD card. Each entry in `menu/title.csv`
is a short title ID and uses this layout:

```text
menu/
  title.csv
  title/<id>/<id>_e.z64
  title/<id>/<id>_e.sprite
  title/<id>/<id>_e.save
  title/<id>/<id>_e.name
  save/<id>.sav
```

The optional `.name` sidecar stores the display name used by the header's
five-row navigator. Existing libraries without it fall back to the internal ROM
title. The importer writes `.name` automatically.

The optional `.save` sidecar configures cartridge saving. Its contents must be one
of:

- `none`
- `eeprom4k`
- `eeprom16k`
- `sram`
- `srambanked`
- `sram128k`
- `flashram`
- `flashram-pkst2`

Legacy sidecars containing numeric values `0` through `7` are also accepted using
the enum order above. New tools should always write the named values.

If the sidecar is absent or invalid, cartridge saving is disabled. When saving is
enabled, the menu creates the correctly sized `.sav` file under `menu/save`,
initializes it to `0xFF`, loads it before boot, and enables flashcart save
writeback.

## Building

See [BUILDING.md](BUILDING.md).

## Library importer

`m64importer` is a native Zig/Sokol application for Windows, Linux and macOS. It
first checks a mounted SummerCart SD card or powered-off USB cart for the installed
base-game library. Mounted ROMs are read directly; USB ROMs are mirrored into a local
cache. If no cart library is available, it finds RetroArch's Nintendo 64 playlist and
resolves its ROM paths. A ROM directory can also be dropped onto the window for
recursive `.n64`, `.v64`, and `.z64` discovery.

Playlist labels become menu names and Android `/storage/<volume>/...` paths are
remapped to mounted desktop drives when possible. For dropped directories, filenames
become menu names and images beside each ROM are selected automatically. ROMs without
artwork are highlighted and include a button that downloads ranked Nintendo 64 images
from the LaunchBox Games Database into a local cache. The closest match to the menu's
landscape aspect ratio is selected first, and **Next Art** cycles the alternatives.
Missing artwork for known mods uses the same gallery. All supported ROM byte orders
are normalized before stable IDs are generated. As a final fallback, drop a supported
image onto the window to assign it to the selected game or the selected mod.

On refresh, the importer also reads the existing SummerCart `title.csv` and name
sidecars. The UI shows the current installed library and a sync plan containing
add, keep, update and hide counts. Hidden titles are removed only from the visible
catalog; existing save files are never deleted.

For the fastest update, remove the SummerCart SD card and connect it to the computer.
The importer detects an existing card by `sc64menu.n64` plus `menu/title.csv`, copies
the staged tree directly, preserves `menu/save` and unrelated files, and publishes
the synchronized catalog last. Automatic direct writes are enabled only for exactly
one removable Windows drive with both markers.

USB remains available as a slower fallback. It uses a patched `sc64deployer sd sync`
command that uploads the entire
staged tree through one device and FatFs session. This avoids reconnecting and
reinitializing the SD card for every ROM, sprite and sidecar. The catalog is still
published last so a failed transfer cannot reference incomplete title assets.

Install all prerequisites and launch it through mise:

```console
mise install
mise run importer-run
```

The app detects RetroArch, mounted SummerCart SD cards and USB carts automatically.
Use **Refresh** to repeat detection, **Sync to SD (Fast)** for the recommended direct
copy, or **Sync over USB (Slow)** when removing the card is inconvenient. USB sync is
blocked unless the cart reports that the console is powered off. Drop a directory to
use it as the active recursive ROM source. An `.lpl` file may be dropped as a fallback
when automatic playlist discovery cannot find the intended installation.

The menu loads cover art only for visible rows and supports large catalogs without
a fixed title-count limit.

The importer also includes a small demo mod catalog assembled from public metadata
sources. Compatible BPS and VCDIFF patches are matched locally by normalized ROM
CRC, downloaded only after user confirmation, and verified against pinned SHA-256
values. ZIP releases contribute only the registry-pinned patch member; bundled
executables are ignored. Downloaded mods are applied on the desktop during sync.
Only base games remain in `title.csv`; generated full-ROM variants are staged under
`menu/title/<id>/variants/` with a `variants.csv` manifest. In the N64 menu,
C-Left/C-Right cycles the original game and up to eight variants before launching.
Variant saves use separate filenames.

ROMs with the same revision-stripped title and N64 cartridge identity are grouped as
one game. The highest header revision becomes the base, while older revisions appear
before downloaded mods in the same versions browser and `variants.csv`.

Development commands:

```console
mise run importer-test
mise run importer-build
```

## Releases

Push a version tag such as `v0.1.0` to build and publish a GitHub Release. The
release contains `sc64menu.n64` and `sc64menu.n64.sha256`, built by the same
clean-machine workflow used for pull requests. Non-version tags do not publish.
