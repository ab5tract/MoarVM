//! Zig port of src/gc/debug.c (lines 1-73), all of which is under
//! `#if MVM_GC_DEBUG`: the region finder and the per-collection log writer
//! ($MVM_GC_LOG). Faithful port; no behaviour change. At
//! `c.MVM_GC_DEBUG == 0` nothing here is analysed or exported, as the C
//! file compiles to nothing. The log line goes through `c.fprintf` with the
//! C's format string, its `PRIu32`/`PRIu64` taken from the translated
//! `<inttypes.h>` macros, so the bytes are the C's by construction. The
//! `MVM_load`s use src/zig/gc/atomic.zig.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const atomic = @import("atomic.zig");

const Tc = [*c]c.MVMThreadContext;

/// Takes a pointer of a GC-allocated object, and goes through all of the
/// alive thread's fromspace/tospace regions and all gen2 pages to try and
/// find the region the pointer is part of. (debug.c:7-45)
pub fn findRegion(tc: Tc, ptr: ?*anyopaque) callconv(.c) void {
    const p = @intFromPtr(ptr);
    var cur_thread: [*c]c.MVMThread = tc.*.instance.*.threads;
    while (cur_thread != null) {
        const thread_tc: Tc = cur_thread.*.body.tc;
        if (thread_tc != null) {
            if (p >= @intFromPtr(thread_tc.*.nursery_fromspace) and
                p < @intFromPtr(thread_tc.*.nursery_fromspace) + thread_tc.*.nursery_fromspace_size)
            {
                _ = c.printf("In fromspace of thread %d\n", @as(c_uint, cur_thread.*.body.thread_id));
                return;
            }
            if (p >= @intFromPtr(thread_tc.*.nursery_tospace) and
                p < @intFromPtr(thread_tc.*.nursery_tospace) + thread_tc.*.nursery_tospace_size)
            {
                _ = c.printf("In tospace of thread %d\n", @as(c_uint, cur_thread.*.body.thread_id));
                return;
            }
            if (thread_tc.*.gen2 != null) {
                const gen2 = thread_tc.*.gen2;
                var bin: c.MVMint32 = 0;
                while (bin < c.MVM_GEN2_BINS) : (bin += 1) {
                    const szc: [*c]c.MVMGen2SizeClass = &gen2.*.size_classes[@intCast(bin)];
                    var page: c.MVMuint32 = 0;
                    while (page < szc.*.num_pages) : (page += 1) {
                        const page_start: [*c]u8 = szc.*.pages[page];
                        const page_size: usize = @intCast(c.MVM_GEN2_PAGE_ITEMS * ((bin + 1) << c.MVM_GEN2_BIN_BITS));
                        const page_end: [*c]u8 = page_start + page_size;
                        if (p >= @intFromPtr(page_start) and p < @intFromPtr(page_end)) {
                            _ = c.printf("In gen2 bin of thread %d\n", @as(c_uint, cur_thread.*.body.thread_id));
                            return;
                        }
                    }
                }
            }
        }
        cur_thread = cur_thread.*.body.next;
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
pub fn logCollection(tc: Tc, for_tc: Tc, full: c.MVMuint8) callconv(.c) void {
    const log = tc.*.instance.*.gc_debug_log;
    if (log != null) {
        _ = c.fprintf(
            log,
            log_format,
            @as(c.MVMuint64, atomic.load(&tc.*.instance.*.gc_seq_number)), // MVM_load, debug.c:57
            @as(c.MVMuint32, for_tc.*.thread_id),
            @as(c_int, if (full != 0) 1 else 0),
            @as(c_int, if (for_tc == tc.*.instance.*.thread_to_blame_for_gc) 1 else 0),
            @as(c.MVMuint32, for_tc.*.nursery_fromspace_size),
            @as(c.MVMuint32, for_tc.*.nursery_tospace_size),
            @as(c.MVMuint32, for_tc.*.gc_promoted_bytes),
            @as(c.MVMuint64, atomic.load(&tc.*.instance.*.gc_promoted_bytes_since_last_full)), // MVM_load, debug.c:64
            @as(c.MVMuint64, for_tc.*.gc_debug_gen2_freed_bytes),
            @as(c.MVMuint32, for_tc.*.gc_debug_stables_freed),
            @as(c.MVMuint32, for_tc.*.num_finalizing),
        );
        _ = c.fflush(log);
    }
    for_tc.*.gc_debug_gen2_freed_bytes = 0;
    for_tc.*.gc_debug_stables_freed = 0;
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.builtin.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

// `#if MVM_GC_DEBUG` (debug.c:3): nothing is exported, or analysed, at 0.
comptime {
    if (c.MVM_GC_DEBUG != 0) {
        @export(&findRegion, .{ .name = "MVM_gc_debug_find_region", .visibility = visibility });
        @export(&logCollection, .{ .name = "MVM_gc_debug_log_collection", .visibility = visibility });
    }
}
