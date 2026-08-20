# n64menu

A proof-of-concept flashcart menu for the Nintendo 64. It supports SummerCart64 and 64drive.

## SD card layout

Install `sc64menu.n64` at the root of the SD card. Each entry in `menu/title.csv` is a short title ID and uses this layout:

```text
menu/
  title.csv
  title/<id>/<id>_e.z64
  title/<id>/<id>_e.sprite
  title/<id>/<id>_e.save
  save/<id>.sav
```

The optional `.save` sidecar configures cartridge saving. Its contents must be one of:

- `none`
- `eeprom4k`
- `eeprom16k`
- `sram`
- `srambanked`
- `sram128k`
- `flashram`
- `flashram-pkst2`

If the sidecar is absent or invalid, cartridge saving is disabled. When saving is enabled, the menu creates the correctly sized `.sav` file under `menu/save`, initializes it to `0xFF`, loads it before boot, and enables flashcart save writeback.
