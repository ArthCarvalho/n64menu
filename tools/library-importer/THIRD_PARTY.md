# Third-party dependencies

`m64importer` statically links the following dependencies. Exact revisions and
package hashes are pinned in `build.zig.zon`.

- [sokol-zig](https://github.com/floooh/sokol-zig), including the Sokol C headers,
  is licensed under the zlib license.
- [zigimg](https://github.com/zigimg/zigimg) is licensed under the MIT license.
- [sc64deployer](https://github.com/Polprzewodnikowy/SummerCart64), distributed
  beside release builds as a separate executable, is licensed under GPL-3.0-or-later.
  The exact corresponding source for the bundled v2.20.2 binary is available at
  <https://github.com/Polprzewodnikowy/SummerCart64/tree/v2.20.2/sw/deployer>.

The Sokol and zigimg licenses are included in the dependency source archives resolved
by Zig's package manager. `sc64deployer` remains a separate executable beside the
importer rather than being linked into it. All licenses must be preserved when
redistributing source or binaries.
