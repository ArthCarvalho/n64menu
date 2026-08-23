# Registry fixture

`registry-v1.json` is a small metadata-only test snapshot assembled from public
machine-readable sources. It intentionally covers direct BPS downloads, direct
VCDIFF downloads, and a BPS patch inside a ZIP release.

No patches, ROMs, screenshots, or cover art are stored in this repository.
Artifact hashes were computed from temporary downloads on 2026-08-23. The
fixture does not assert that public availability grants redistribution rights;
every record currently disables patch and artwork redistribution.

Sources:

- RHDC public JSON API: `https://api.romhacking.com/`
- Smash Remix official patch manifest: `https://smashremix.net/patcher/patches/releases.json`
- GitHub Releases API: `https://api.github.com/`

This is test data, not a production registry or endorsement list. A production
registry should live separately, use immutable signed snapshots, obtain source
operator or maintainer approval, and carry explicit per-entry provenance and
rights metadata.
