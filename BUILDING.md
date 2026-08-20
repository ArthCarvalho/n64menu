# Building with Zig

Windows builds are self-contained and do not require WSL.

## Requirements

- Zig 0.14 or newer, optionally installed through mise
- Git for Windows
- Internet access for the first build

Clone the repository to a local path containing only letters, numbers, dots, underscores, and hyphens; the historical libdragon Makefiles do not safely quote tool paths.

```powershell
mise use zig@0.14
mise run menu
```

The first build downloads a checksum-pinned official native libdragon MIPS64 toolchain into `.n64`, recovers the libdragon revision used by n64menu's initial commit, and writes `zig-out/bin/sc64menu.n64`. Subsequent builds reuse the local cache.

The host `n64tool` and `n64sym` utilities are compiled by Zig from a pinned historical source archive. Git Bash supplies the POSIX shell expected by libdragon's existing Makefiles; WSL and Docker are not used.
