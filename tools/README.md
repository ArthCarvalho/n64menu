# Library importer

`import-library.ps1` prepares ROMs and artwork for n64menu on Windows PowerShell 5.1.

```powershell
.\tools\import-library.ps1 `
  -OutputRoot E:\ `
  -RomPath C:\Roms `
  -RetroArchThumbnailPath C:\RetroArch\thumbnails\Nintendo64 `
  -Recursive `
  -DownloadMissingBoxart
```

The importer:

- supports `.z64`, `.v64`, and `.n64` ROMs and writes canonical `.z64` byte order;
- generates stable five-character IDs that fit n64menu's 256-byte catalog buffer;
- prioritizes an image beside each ROM, including a single arbitrarily named image;
- optionally searches a separate image directory and RetroArch's `Named_Boxarts`;
- optionally downloads exact matches from the upstream `libretro-thumbnails/Nintendo_-_Nintendo_64` repository;
- converts images to n64menu's 256x179 libdragon RGBA16 sprite format;
- generates a plain title card when no artwork exists.

No ROMs or artwork are included in this repository. Verify the licensing of artwork you download or supply.
