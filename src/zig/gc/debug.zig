//! Zig port of src/gc/debug.c (lines 1-73), all of which is under
//! `#if MVM_GC_DEBUG`: the region finder and the per-collection log writer
//! ($MVM_GC_LOG, opened by MVM_vm_create_instance, src/moar.c:175-185).
//! No behaviour change. At `c.MVM_GC_DEBUG == 0` nothing here is analysed
//! or exported, as the C file compiles to nothing. The log line goes
//! through `c.fprintf` with the C's format string, its `PRIu32`/`PRIu64`
//! taken from the translated `<inttypes.h>` macros, and the C's arguments
//! in the C's order and widths, so the bytes are the C's by construction
//! (the oracle compares them). The `MVM_load`s use src/zig/gc/atomic.zig.
//! The functions are Zig-typed; the `MVM_gc_debug_*` exports are thin
//! C-ABI wrappers over them.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const atomic = @import("atomic.zig");
const view = @import("view.zig");
const gen2_mod = @import("gen2.zig");

const Tc = view.Tc;
const Gen2 = view.Gen2;
const Thread = view.Thread;

/// `start <= p < start + size`, as the C compares a pointer with a region.
fn within(p: usize, start: ?*const anyopaque, size: usize) bool {
    return p >= @intFromPtr(start) and p < @intFromPtr(start) + size;
}

/// Takes a pointer of a GC-allocated object, and goes through all of the
/// alive thread's fromspace/tospace regions and all gen2 pages to try and
/// find the region the pointer is part of. (debug.c:7-45)
pub fn findRegion(tc: Tc, ptr: ?*anyopaque) void {
    const p = @intFromPtr(ptr);
    var cur_thread: ?Thread = tc.instance.*.threads;
    while (cur_thread) |thread| : (cur_thread = thread.body.next) {
        const thread_tc: Tc = thread.body.tc orelse continue;
        const thread_id: c_uint = thread.body.thread_id;
        if (within(p, thread_tc.nursery_fromspace, thread_tc.nursery_fromspace_size)) {
            _ = c.printf("In fromspace of thread %d\n", thread_id);
            return;
        }
        if (within(p, thread_tc.nursery_tospace, thread_tc.nursery_tospace_size)) {
            _ = c.printf("In tospace of thread %d\n", thread_id);
            return;
        }
        const gen2: Gen2 = thread_tc.gen2 orelse continue;
        for (gen2.size_classes[0..c.MVM_GEN2_BINS], 0..) |szc, bin| {
            const page_size: usize = @as(usize, c.MVM_GEN2_PAGE_ITEMS) * gen2_mod.sizeOfBin(@intCast(bin));
            for (szc.pages[0..szc.num_pages]) |page_start| {
                if (within(p, page_start, page_size)) {
                    _ = c.printf("In gen2 bin of thread %d\n", thread_id);
                    return;
                }
            }
        }
    }
    _ = c.printf("Not found\n");
}

/// The format string of debug.c:54-56, as the C preprocessor pastes it.
const log_format = "seq=%" ++ c.PRIu64 ++ " tid=%" ++ c.PRIu32 ++ " full=%d coord=%d from=%" ++ c.PRIu32 ++ " next=%" ++ c.PRIu32 ++
    " promoted=%" ++ c.PRIu32 ++ " since_full=%" ++ c.PRIu64 ++ " gen2_freed=%" ++ c.PRIu64 ++
    " stables_freed=%" ++ c.PRIu32 ++ " finalizing=%" ++ c.PRIu32 ++ "\n";

/// Writes one line of the per-collection log ($MVM_GC_LOG) for the run that
/// tc has just finished on behalf of for_tc, then resets for_tc's counters.
/// coord is 1 for the thread that started the run. (debug.c:50-72)
pub fn logCollection(tc: Tc, for_tc: Tc, full: bool) void {
    const i: view.Instance = tc.instance;
    if (@as(?*c.FILE, i.gc_debug_log)) |log| {
        _ = c.fprintf(
            log,
            log_format,
            @as(c.MVMuint64, atomic.load(&i.gc_seq_number)), // MVM_load, debug.c:57
            @as(c.MVMuint32, for_tc.thread_id),
            @as(c_int, @intFromBool(full)),
            @as(c_int, @intFromBool(for_tc == i.thread_to_blame_for_gc)),
            @as(c.MVMuint32, for_tc.nursery_fromspace_size),
            @as(c.MVMuint32, for_tc.nursery_tospace_size),
            @as(c.MVMuint32, for_tc.gc_promoted_bytes),
            @as(c.MVMuint64, atomic.load(&i.gc_promoted_bytes_since_last_full)), // MVM_load, debug.c:64
            @as(c.MVMuint64, for_tc.gc_debug_gen2_freed_bytes),
            @as(c.MVMuint32, for_tc.gc_debug_stables_freed),
            @as(c.MVMuint32, for_tc.num_finalizing),
        );
        _ = c.fflush(log);
    }
    for_tc.gc_debug_gen2_freed_bytes = 0;
    for_tc.gc_debug_stables_freed = 0;
}

// ---- the C ABI -------------------------------------------------------------

fn findRegionExport(tc: [*c]c.MVMThreadContext, ptr: ?*anyopaque) callconv(.c) void {
    findRegion(tc, ptr);
}

fn logCollectionExport(tc: [*c]c.MVMThreadContext, for_tc: [*c]c.MVMThreadContext, full: c.MVMuint8) callconv(.c) void {
    // `full ? 1 : 0` (debug.c:59).
    logCollection(tc, for_tc, full != 0);
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.lang.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

// `#if MVM_GC_DEBUG` (debug.c:3): nothing is exported, or analysed, at 0.
comptime {
    if (c.MVM_GC_DEBUG != 0) {
        @export(&findRegionExport, .{ .name = "MVM_gc_debug_find_region", .visibility = visibility });
        @export(&logCollectionExport, .{ .name = "MVM_gc_debug_log_collection", .visibility = visibility });
    }
}
