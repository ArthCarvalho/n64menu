# Third-party dependencies

`m64importer` statically links the following dependencies. Exact revisions and
package hashes are pinned in `build.zig.zon`.

- [sokol-zig](https://github.com/floooh/sokol-zig), including the Sokol C headers,
  is licensed under the zlib license.
- [zigimg](https://github.com/zigimg/zigimg) is licensed under the MIT license.
- [sc64deployer](https://github.com/Polprzewodnikowy/SummerCart64), distributed
  beside release builds as a separate executable, is licensed under GPL-3.0-or-later.
  It is built from pinned upstream commit `a1e7996` with the adjacent
  `sc64deployer-batch-sync.patch`, which
  adds one directory-tree upload command so a sync uses one USB/FatFs session. The
  unmodified corresponding source is available at
  <https://github.com/Polprzewodnikowy/SummerCart64/tree/a1e7996d2cbece686820a5c785029c68514f17b0/sw/deployer>.
  The batching change is proposed upstream in
  <https://github.com/Polprzewodnikowy/SummerCart64/pull/128>.

The Sokol and zigimg licenses are included in the dependency source archives resolved
by Zig's package manager. `sc64deployer` remains a separate executable beside the
importer rather than being linked into it. All licenses must be preserved when
redistributing source or binaries.
