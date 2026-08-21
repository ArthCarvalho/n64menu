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
- `tools/import-library.ps1`, which prepares ROMs and box art for the SD card.

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
- The M64 wordmark rendered by the menu is a ModRetro trademark, used here for
  identification only. No affiliation with or endorsement by ModRetro is claimed,
  and the MIT License does not grant trademark rights.
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
