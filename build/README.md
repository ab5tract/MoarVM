## Configure- and Build-time Tools and Templates

These tools and templates abstract away platform and target differences when it
comes to building the software.


## zig build

`build.zig` and `build/zig/` provide an alternative build that needs only
zig; see `docs/zig-build.md`. `build/sources.list` is shared by both builds:
add new C files there, not in `Makefile.in`.
