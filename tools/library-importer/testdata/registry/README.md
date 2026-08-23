# Registry fixture

`registry-v1.json` is a small metadata-only test snapshot assembled from public
machine-readable sources. It intentionally covers direct BPS downloads, direct
VCDIFF downloads, and a BPS patch inside a ZIP release.

No patches, ROMs, screenshots, or cover art are stored in this repository.
Artifact hashes were computed from temporary downloads on 2026-08-23. The
fixture does not assert that public availability grants redistribution rights;
every record currently disables patch and artwork redistribution.

Some records include a source-provided screenshot URL and pinned SHA-256. The
importer downloads those images only into the user's local cache and does not
redistribute them. Project-page links add `utm_source=m64menu`,
`utm_medium=desktop_app`, and `utm_campaign=mod_catalog` so maintainers can see
traffic driven by the importer. Entries without source artwork offer a
LaunchBox search instead of scraping LaunchBox media.

Sources:

- RHDC public JSON API: `https://api.romhacking.com/`
- Smash Remix official patch manifest: `https://smashremix.net/patcher/patches/releases.json`
- GitHub Releases API: `https://api.github.com/`

This is test data, not a production registry or endorsement list. A production
registry should live separately, use immutable signed snapshots, obtain source
operator or maintainer approval, and carry explicit per-entry provenance and
rights metadata.
