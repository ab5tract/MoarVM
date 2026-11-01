//! Everything `zig build install` puts under the prefix besides the two
//! artifacts (bin/moar, lib/libmoar.so), mirroring the `install:` target of
//! build/Makefile.in for the moar backend.
const std = @import("std");

pub fn addAll(
    b: *std.Build,
    libmoar: *std.Build.Step.Compile,
    config_h: *std.Build.Step.ConfigHeader,
    pc: std.Build.LazyPath,
) void {
    // Headers travel with libmoar so dependents (nqp's build.zig, phase 3)
    // get them on their include path by linking the artifact.
    libmoar.installHeadersDirectory(b.path("src"), "moar", .{});
    libmoar.installHeader(config_h.getOutputFile(), "moar/config.h");
    libmoar.installHeader(config_h.getOutputFile(), "moar/gen/config.h");
    libmoar.installHeadersDirectory(b.path("3rdparty/libuv/include"), "libuv", .{});
    libmoar.installHeadersDirectory(b.path("3rdparty/libtommath"), "libtommath", .{});
    libmoar.installHeadersDirectory(b.path("3rdparty/dyncall/dyncall"), "dyncall", .{});
    libmoar.installHeadersDirectory(b.path("3rdparty/dyncall/dyncallback"), "dyncall", .{});
    libmoar.installHeadersDirectory(b.path("3rdparty/dyncall/dynload"), "dyncall", .{});
    libmoar.installHeadersDirectory(b.path("3rdparty/mimalloc/include"), "mimalloc", .{});
    libmoar.installHeader(b.path("3rdparty/zmij/zmij-c.h"), "zmij/zmij-c.h");

    const install = b.getInstallStep();
    install.dependOn(&b.addInstallFileWithDir(b.path("tools/libmoar.so-gdb.py"), .lib, "libmoar.so-gdb.py").step);
    install.dependOn(&b.addInstallFileWithDir(b.path("lib/MAST/Nodes.nqp"), .{ .custom = "share/nqp/lib/MAST" }, "Nodes.nqp").step);
    install.dependOn(&b.addInstallFileWithDir(b.path("lib/MAST/Ops.nqp"), .{ .custom = "share/nqp/lib/MAST" }, "Ops.nqp").step);
    install.dependOn(&b.addInstallFileWithDir(pc, .{ .custom = "share/pkgconfig" }, "moar.pc").step);
}
