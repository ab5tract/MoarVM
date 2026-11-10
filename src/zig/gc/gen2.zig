//! Zig port of src/gc/gen2.c (lines 1-291): the second generation
//! allocator, a set of fixed size-class bins of 256-item pages plus a list
//! of overflow blocks malloc'd for anything larger than the last bin.
//! No behaviour change. The structs and constants stay in src/gc/gen2.h;
//! all memory goes through `MVM_malloc`/`MVM_calloc`/`MVM_realloc`/
//! `MVM_free` as in the C, so collect.c and the other C callers keep walking
//! `size_classes`, `pages` and `overflows` directly. The free list is
//! threaded through the first word of a freed item (`FreeNode`); the sweep
//! in collect.c pushes items onto it (and, under MVM_GC_DEBUG, sets
//! MVM_CF_DEBUG_IN_GEN2_FREE_LIST on them); gen2.c only pops it, so that
//! flag is not touched here. The functions are Zig-typed; the
//! `MVM_gc_gen2_*` exports are thin C-ABI wrappers over them.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const view = @import("view.zig");

const Tc = view.Tc;
const Instance = view.Instance;
const Gen2 = view.Gen2;
const SizeClass = c.MVMGen2SizeClass;

const BIN_BITS: u5 = c.MVM_GEN2_BIN_BITS;
const BIN_MASK: u32 = c.MVM_GEN2_BIN_MASK;
const BINS: u32 = c.MVM_GEN2_BINS;
const PAGE_ITEMS: u32 = c.MVM_GEN2_PAGE_ITEMS;

/// The bin of a request (gen2.c:63-68). If we hit a bin exactly then it's
/// off-by-one, since the bins list is base-0; otherwise the extra bits round
/// us up to the next bin, which is a no-op. MVMuint32 arithmetic: a size of
/// 0 wraps to 0xFFFFFFFF and takes the overflow path, as in the C.
pub inline fn binOf(size: c.MVMuint32) c.MVMuint32 {
    var bin: c.MVMuint32 = size >> BIN_BITS;
    if ((size & BIN_MASK) == 0)
        bin -%= 1;
    return bin;
}

/// The item size of a bin, `(bin + 1) << MVM_GEN2_BIN_BITS` (gen2.c:22, 40,
/// 88, 158), in MVMuint32.
pub inline fn sizeOfBin(bin: c.MVMuint32) c.MVMuint32 {
    return (bin +% 1) << BIN_BITS;
}

comptime {
    std.debug.assert(sizeOfBin(BINS - 1) == 320);
    std.debug.assert(binOf(8) == 0 and binOf(9) == 1 and binOf(320) == BINS - 1 and binOf(321) == BINS);
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(c.MVMGen2SizeClass) == 40);
        std.debug.assert(@sizeOf(c.MVMGen2Allocator) == 24);
    }
}

// ---- the free list ---------------------------------------------------------

/// A free item of a bin: its first word holds the next free item, the C's
/// `char **` threading. The head field `free_list` of a size class has the
/// same one-word shape, which is what lets the C walk both with one
/// `char ***` (MVM_gc_gen2_transfer's `freelist_insert_pos`).
pub const FreeNode = extern struct { next: ?*FreeNode };

comptime {
    std.debug.assert(@sizeOf(FreeNode) == @sizeOf(usize));
    std.debug.assert(@sizeOf(@FieldType(SizeClass, "free_list")) == @sizeOf(usize));
}

/// The word at `word` (a free item, or the `free_list` field of a size
/// class) as a free-list node: the one view of the threading.
inline fn node(word: anytype) *FreeNode {
    return @ptrCast(@alignCast(word));
}

/// The free-list head of `sc`, as a link.
inline fn freeList(sc: *SizeClass) *?*FreeNode {
    return &node(&sc.free_list).next;
}

// ---- slices over the C's lists ---------------------------------------------

/// The size classes of `al`, `MVM_GEN2_BINS` of them.
inline fn sizeClasses(al: Gen2) []SizeClass {
    return al.size_classes[0..BINS];
}

/// The slice type of a C list field `P` (a pointer to its first element).
fn List(comptime P: type) type {
    return []@typeInfo(P).pointer.child;
}

/// `ptr[0..len]` of a C list field `ptr` with its count `len`, which the C
/// may hold as NULL with a zero count (a bin never set up, an overflow or
/// root list freed by transfer): slicing a NULL `[*c]` is not allowed.
inline fn list(ptr: anytype, len: u32) List(@TypeOf(ptr)) {
    return if (len == 0) &.{} else ptr[0..len];
}

/// The slots of `size` bytes from `from` up to `to`, in address order, as
/// the C walks them with `while (cur_ptr < end_ptr) cur_ptr += size`: none
/// when `to` is not above `from`.
pub const Slots = struct {
    bytes: []u8,
    size: u32,
    off: usize = 0,

    pub fn init(from: [*]u8, to: [*]u8, size: u32) Slots {
        if (@intFromPtr(to) <= @intFromPtr(from)) return .{ .bytes = &.{}, .size = size };
        return .{ .bytes = from[0 .. @intFromPtr(to) - @intFromPtr(from)], .size = size };
    }

    pub fn next(s: *Slots) ?[*]u8 {
        if (s.off >= s.bytes.len) return null;
        const slot = s.bytes[s.off..].ptr;
        s.off += s.size;
        return slot;
    }
};

/// The slots of page `k` of `sc` (gen2.c:191-196): the whole page, except
/// the last, the one being allocated in, which ends at `alloc_pos`.
pub fn pageItems(sc: *const SizeClass, k: usize, obj_size: u32) Slots {
    const pages = sc.pages[0..sc.num_pages];
    const page = pages[k];
    const end = if (k + 1 == pages.len) sc.alloc_pos else page + obj_size *% PAGE_ITEMS;
    return .init(page, end, obj_size);
}

// ---- the allocator ---------------------------------------------------------

/// Creates a new second generation allocator. (gen2.c:3-17)
pub fn create(i: Instance) Gen2 {
    _ = i;
    // Create allocator data structure.
    const al: Gen2 = @ptrCast(@alignCast(c.MVM_malloc(@sizeOf(c.MVMGen2Allocator))));

    // Create empty size classes array data structure.
    al.size_classes = @ptrCast(@alignCast(c.MVM_calloc(BINS, @sizeOf(SizeClass))));

    // Set up overflows area.
    al.alloc_overflows = c.MVM_GEN2_OVERFLOWS;
    al.num_overflows = 0;
    al.overflows = @ptrCast(@alignCast(c.MVM_malloc(@as(usize, al.alloc_overflows) * @sizeOf(view.Col))));

    return al;
}

/// Sets up the size class of `bin` in the second generation. (gen2.c:19-35)
fn setupBin(sc: *SizeClass, bin: u32) void {
    // Work out page size we want.
    const page_size: u32 = PAGE_ITEMS *% sizeOfBin(bin);

    // We'll just allocate a single page to start off with.
    sc.num_pages = 1;
    sc.pages = @ptrCast(@alignCast(c.MVM_malloc(@sizeOf(?*anyopaque) * @as(usize, sc.num_pages))));
    sc.pages[0] = @ptrCast(c.MVM_malloc(page_size));

    // Set up allocation position and limit.
    sc.alloc_pos = sc.pages[0];
    sc.alloc_limit = sc.alloc_pos + page_size;

    // Free list is empty until GC run (and we just do page by page allocation).
    sc.free_list = null;
}

/// Adds a new page to the size class of `bin`. (gen2.c:37-55)
fn addPage(sc: *SizeClass, bin: u32) void {
    // Work out page size.
    const page_size: u32 = PAGE_ITEMS *% sizeOfBin(bin);

    // Add the extra page.
    const cur_page = sc.num_pages;
    sc.num_pages +%= 1;
    sc.pages = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(sc.pages), @sizeOf(?*anyopaque) * @as(usize, sc.num_pages))));
    sc.pages[cur_page] = @ptrCast(c.MVM_malloc(page_size));

    // Set up allocation position and limit.
    sc.alloc_pos = sc.pages[cur_page];
    sc.alloc_limit = sc.alloc_pos + page_size;

    // set the cur_page to a proper value
    sc.cur_page = cur_page;
}

/// Allocates space using the second generation allocator and returns a
/// pointer to the allocated space. Does not zero the space or set it up in
/// any way. (gen2.c:57-105)
pub fn allocate(al: Gen2, size: u32) *anyopaque {
    // Determine the bin (gen2.c:66-68).
    const bin = binOf(size);

    // If the selected bin is in range...
    if (bin < BINS) {
        const sc = &sizeClasses(al)[bin];

        // If we've no pages yet, never encountered this bin; set it up.
        if (sc.pages == null)
            setupBin(sc, bin);

        // If there's a free list entry, use that.
        const free = freeList(sc);
        if (free.*) |item| {
            free.* = item.next;
            return item;
        }

        // If we're at the page limit, add a new page.
        if (sc.alloc_pos == sc.alloc_limit)
            addPage(sc, bin);

        // Now we can allocate.
        const result: *anyopaque = sc.alloc_pos;
        sc.alloc_pos += sizeOfBin(bin);
        return result;
    }

    // We're beyond the size class bins, so resort to malloc.
    const result = c.MVM_malloc(size).?;

    // Add to overflows list.
    if (al.num_overflows == al.alloc_overflows) {
        al.alloc_overflows *%= 2;
        al.overflows = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(al.overflows), @as(usize, al.alloc_overflows) * @sizeOf(view.Col))));
    }
    al.overflows[al.num_overflows] = view.asCol(result);
    al.num_overflows +%= 1;
    return result;
}

/// Allocates space using the second generation allocator and returns a
/// pointer to the allocated space. Promises the memory will be zeroed,
/// except that the MVMCollectable gen 2 flag will get set. (gen2.c:107-115)
pub fn allocateZeroed(al: Gen2, size: u32) *anyopaque {
    const a = allocate(al, size);
    @memset(@as([*]u8, @ptrCast(a))[0..size], 0);
    view.flags2(view.asCol(a)).* = .{ .second_gen = true };
    return a;
}

/// Frees all memory associated with the second generation. (gen2.c:117-139)
pub fn destroy(i: Instance, al: Gen2) void {
    _ = i;
    // Remove all pages.
    for (sizeClasses(al)) |sc| {
        for (list(sc.pages, sc.num_pages)) |page|
            c.MVM_free(@ptrCast(page));
        c.MVM_free(@ptrCast(sc.pages));
    }

    // Free any allocated overflows.
    for (list(al.overflows, al.num_overflows)) |overflow| {
        if (overflow != null)
            c.MVM_free(@ptrCast(overflow));
    }

    // Clean up allocator data structure.
    c.MVM_free(@ptrCast(al.size_classes));
    al.size_classes = null;
    c.MVM_free(@ptrCast(al.overflows));
    al.overflows = null;
    c.MVM_free(al);
}

/// Blindly move pages from one gen2 to another. (gen2.c:141-267)
pub fn transfer(src: Tc, dest: Tc) void {
    const gen2: Gen2 = src.gen2;
    const dest_gen2: Gen2 = dest.gen2;

    for (sizeClasses(gen2), sizeClasses(dest_gen2), 0..) |*sc, *dest_sc, bin| {
        const orig_dest_num_pages = dest_sc.num_pages;
        // If we've nothing allocated in this size class, skip it.
        if (sc.pages == null)
            continue;

        if (dest_sc.pages == null)
            dest_sc.free_list = null;

        // Calculate object size for this bin.
        const obj_size = sizeOfBin(@intCast(bin));

        // freelist_insert_pos is the link that stores the address of the
        // last traversed free list node (the C's char ***). Initialize
        // freelist insertion position to free list head.
        var freelist_insert_pos = freeList(sc);

        if (dest_sc.pages == null) {
            dest_sc.pages = @ptrCast(@alignCast(c.MVM_malloc(@sizeOf(?*anyopaque) * @as(usize, sc.num_pages))));
            dest_sc.num_pages = sc.num_pages;
        } else {
            dest_sc.num_pages +%= sc.num_pages;
            dest_sc.pages = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(dest_sc.pages), @sizeOf(?*anyopaque) * @as(usize, dest_sc.num_pages))));
        }
        const dest_pages = dest_sc.pages[0..dest_sc.num_pages];

        // Visit each page in the source.
        for (sc.pages[0..sc.num_pages], 0..) |page, k| {
            // Visit all the objects, looking for dead ones and swap the
            // owner for each of them.
            var slots = pageItems(sc, k, obj_size);
            while (slots.next()) |slot| {
                if (@intFromPtr(slot) == @intFromPtr(freelist_insert_pos)) {
                    // skip
                } else if (@intFromPtr(slot) == @intFromPtr(freelist_insert_pos.*)) {
                    freelist_insert_pos = &node(slot).next;
                } else { // note: we don't have tests that exercise this path yet.
                    view.asCol(slot).owner = dest.thread_id;
                }
            }
            dest_pages[k + orig_dest_num_pages] = page;
        }

        freelist_insert_pos = freeList(dest_sc);
        while (freelist_insert_pos.*) |n|
            freelist_insert_pos = &n.next;
        // chain the destination's freelist through any remaining unallocated area
        if (dest_sc.alloc_pos != null) {
            var rest: Slots = .init(dest_sc.alloc_pos, dest_sc.alloc_limit, obj_size);
            while (rest.next()) |slot| {
                freelist_insert_pos.* = node(slot);
                freelist_insert_pos = &node(slot).next;
            }
        }

        // link to the new pages, if any
        freelist_insert_pos.* = freeList(sc).*;

        dest_sc.alloc_pos = sc.alloc_pos;
        dest_sc.alloc_limit = sc.alloc_limit;

        c.MVM_free(@ptrCast(sc.pages));
        sc.pages = null;
        sc.num_pages = 0;
    }
    { // transfer the overflows
        if (gen2.num_overflows +% dest_gen2.num_overflows > dest_gen2.alloc_overflows) {
            // double the larger of the 2 sizes
            dest_gen2.alloc_overflows = @max(gen2.alloc_overflows, dest_gen2.alloc_overflows) *% 2;
            dest_gen2.overflows = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(dest_gen2.overflows), @as(usize, dest_gen2.alloc_overflows) * @sizeOf(view.Col))));
        }
        const overflows = list(gen2.overflows, gen2.num_overflows);
        for (overflows) |overflow|
            overflow.*.owner = dest.thread_id;
        // memcpy(&dest_gen2->overflows[dest_gen2->num_overflows], gen2->overflows,
        //        gen2->num_overflows * sizeof(MVMCollectable *))
        @memcpy(dest_gen2.overflows[dest_gen2.num_overflows..][0..overflows.len], overflows);
        dest_gen2.num_overflows +%= gen2.num_overflows;

        gen2.num_overflows = 0;
        gen2.alloc_overflows = 0;
        c.MVM_free(@ptrCast(gen2.overflows));
        gen2.overflows = null;
    }
    { // copy the roots...
        for (list(src.gen2roots, src.num_gen2roots)) |root|
            c.MVM_gc_root_gen2_add(dest, root);
        src.num_gen2roots = 0;
        src.alloc_gen2roots = 0;
        c.MVM_free(@ptrCast(src.gen2roots));
        src.gen2roots = null;
    }
}

/// Compact the overflow list to prevent it from growing without bounds.
/// (gen2.c:270-291)
pub fn compactOverflows(al: Gen2) void {
    const overflows = list(al.overflows, al.num_overflows);

    // Find the first NULL object.
    const first_null: u32 = for (overflows, 0..) |overflow, cursor| {
        if (overflow == null) break @intCast(cursor);
    } else al.num_overflows;

    // Slide others back so the alive ones are at the start of the list.
    var live = first_null;
    for (overflows[first_null..]) |overflow| {
        if (overflow != null) {
            overflows[live] = overflow;
            live += 1;
        }
    }

    al.num_overflows = live;
}

// ---- the C ABI -------------------------------------------------------------

fn createExport(i: [*c]c.MVMInstance) callconv(.c) [*c]c.MVMGen2Allocator {
    return create(i);
}

fn allocateExport(al: [*c]c.MVMGen2Allocator, size: c.MVMuint32) callconv(.c) ?*anyopaque {
    return allocate(al, size);
}

fn allocateZeroedExport(al: [*c]c.MVMGen2Allocator, size: c.MVMuint32) callconv(.c) ?*anyopaque {
    return allocateZeroed(al, size);
}

fn destroyExport(i: [*c]c.MVMInstance, al: [*c]c.MVMGen2Allocator) callconv(.c) void {
    destroy(i, al);
}

fn transferExport(src: [*c]c.MVMThreadContext, dest: [*c]c.MVMThreadContext) callconv(.c) void {
    transfer(src, dest);
}

fn compactOverflowsExport(al: [*c]c.MVMGen2Allocator) callconv(.c) void {
    compactOverflows(al);
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.lang.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&createExport, .{ .name = "MVM_gc_gen2_create", .visibility = visibility });
    @export(&allocateExport, .{ .name = "MVM_gc_gen2_allocate", .visibility = visibility });
    @export(&allocateZeroedExport, .{ .name = "MVM_gc_gen2_allocate_zeroed", .visibility = visibility });
    @export(&destroyExport, .{ .name = "MVM_gc_gen2_destroy", .visibility = visibility });
    @export(&transferExport, .{ .name = "MVM_gc_gen2_transfer", .visibility = visibility });
    @export(&compactOverflowsExport, .{ .name = "MVM_gc_gen2_compact_overflows", .visibility = visibility });
}
