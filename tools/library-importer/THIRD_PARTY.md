# Third-party dependencies

`m64importer` statically links the following dependencies. Exact revisions and
package hashes are pinned in `build.zig.zon`.

- [sokol-zig](https://github.com/floooh/sokol-zig), including the Sokol C headers,
  is licensed under the zlib license.
- [zigimg](https://github.com/zigimg/zigimg) is licensed under the MIT license.
- [sc64deployer](https://github.com/DrSammyD/SummerCart64), distributed
  beside release builds as a separate executable, is licensed under GPL-3.0-or-later.
  It is built from pinned fork commit `df8432c9`, whose directory-tree upload
  command lets each sync use one USB/FatFs session. The corresponding source is
  available at
  <https://github.com/DrSammyD/SummerCart64/tree/df8432c9f18b9d1c5977cf9502e829be06d39d77/sw/deployer>.
  The batching change is proposed upstream in
  <https://github.com/Polprzewodnikowy/SummerCart64/pull/128>.

The Sokol and zigimg licenses are included in the dependency source archives resolved
by Zig's package manager. `sc64deployer` remains a separate executable beside the
importer rather than being linked into it. All licenses must be preserved when
redistributing source or binaries.
