## Configure- and Build-time Tools and Templates

These tools and templates abstract away platform and target differences when it
comes to building the software.

## zig build

`build.zig` and `build/zig/` provide an alternative build that needs only
zig; see `docs/zig-build.md`. `build/sources.list` is shared by both builds:
add new MoarVM C files there, and declare Zig replacements for C files in its
`[zig]` section (see `docs/zig-build.md`, "Zig implementations"). The five
hash tables live in `src/zig/core/hash/` when the Zig groups are on (see
`docs/zig-build.md`, "Hash engine"). The win32
platform sources and the memmem, zmij and mimalloc objects still live in
`Makefile.in` (the zig build handles those itself).
