//! Zig port of src/gc/gen2.c (lines 1-291): the second generation
//! allocator, a set of fixed size-class bins of 256-item pages plus a list
//! of overflow blocks malloc'd for anything larger than the last bin.
//! Faithful port; no behaviour change. The structs and constants stay in
//! src/gc/gen2.h; all memory goes through `MVM_malloc`/`MVM_calloc`/
//! `MVM_realloc`/`MVM_free` as in the C, so collect.c and the other C
//! callers keep walking `size_classes`, `pages` and `overflows` directly.
//! The free list is threaded through the first word of a freed item; the
//! sweep in collect.c pushes items onto it (and, under MVM_GC_DEBUG, sets
//! MVM_CF_DEBUG_IN_GEN2_FREE_LIST on them); gen2.c only pops it, so that
//! flag is not touched here.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;

const Tc = [*c]c.MVMThreadContext;
const Al = [*c]c.MVMGen2Allocator;
const Collectable = c.MVMCollectable;
/// `char ***` in MVM_gc_gen2_transfer.
const FreelistPos = [*c][*c][*c]u8;

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

/// Creates a new second generation allocator. (gen2.c:3-17)
pub fn create(i: [*c]c.MVMInstance) callconv(.c) Al {
    _ = i;
    // Create allocator data structure.
    const al: Al = @ptrCast(@alignCast(c.MVM_malloc(@sizeOf(c.MVMGen2Allocator))));

    // Create empty size classes array data structure.
    al.*.size_classes = @ptrCast(@alignCast(c.MVM_calloc(BINS, @sizeOf(c.MVMGen2SizeClass))));

    // Set up overflows area.
    al.*.alloc_overflows = c.MVM_GEN2_OVERFLOWS;
    al.*.num_overflows = 0;
    al.*.overflows = @ptrCast(@alignCast(c.MVM_malloc(@as(usize, al.*.alloc_overflows) * @sizeOf([*c]Collectable))));

    return al;
}

/// Sets up a size class bin in the second generation. (gen2.c:19-35)
fn setupBin(al: Al, bin: c.MVMuint32) void {
    // Work out page size we want.
    const page_size: c.MVMuint32 = PAGE_ITEMS *% sizeOfBin(bin);

    // We'll just allocate a single page to start off with.
    al.*.size_classes[bin].num_pages = 1;
    al.*.size_classes[bin].pages = @ptrCast(@alignCast(c.MVM_malloc(@sizeOf(?*anyopaque) * @as(usize, al.*.size_classes[bin].num_pages))));
    al.*.size_classes[bin].pages[0] = @ptrCast(c.MVM_malloc(page_size));

    // Set up allocation position and limit.
    al.*.size_classes[bin].alloc_pos = al.*.size_classes[bin].pages[0];
    al.*.size_classes[bin].alloc_limit = al.*.size_classes[bin].alloc_pos + page_size;

    // Free list is empty until GC run (and we just do page by page allocation).
    al.*.size_classes[bin].free_list = null;
}

/// Adds a new page to a size class bin. (gen2.c:37-55)
fn addPage(al: Al, bin: c.MVMuint32) void {
    // Work out page size.
    const page_size: c.MVMuint32 = PAGE_ITEMS *% sizeOfBin(bin);

    // Add the extra page.
    const cur_page: c.MVMuint32 = al.*.size_classes[bin].num_pages;
    al.*.size_classes[bin].num_pages +%= 1;
    al.*.size_classes[bin].pages = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(al.*.size_classes[bin].pages), @sizeOf(?*anyopaque) * @as(usize, al.*.size_classes[bin].num_pages))));
    al.*.size_classes[bin].pages[cur_page] = @ptrCast(c.MVM_malloc(page_size));

    // Set up allocation position and limit.
    al.*.size_classes[bin].alloc_pos = al.*.size_classes[bin].pages[cur_page];
    al.*.size_classes[bin].alloc_limit = al.*.size_classes[bin].alloc_pos + page_size;

    // set the cur_page to a proper value
    al.*.size_classes[bin].cur_page = cur_page;
}

/// Allocates space using the second generation allocator and returns a
/// pointer to the allocated space. Does not zero the space or set it up in
/// any way. (gen2.c:57-105)
pub fn allocate(al: Al, size: c.MVMuint32) callconv(.c) ?*anyopaque {
    var result: ?*anyopaque = undefined;

    // Determine the bin (gen2.c:66-68).
    const bin: c.MVMuint32 = binOf(size);

    // If the selected bin is in range...
    if (bin < BINS) {
        // If we've no pages yet, never encountered this bin; set it up.
        if (al.*.size_classes[bin].pages == null)
            setupBin(al, bin);

        // If there's a free list entry, use that.
        if (al.*.size_classes[bin].free_list != null) {
            result = @ptrCast(al.*.size_classes[bin].free_list);
            al.*.size_classes[bin].free_list = @ptrCast(@alignCast(al.*.size_classes[bin].free_list.*));
        } else {
            // If we're at the page limit, add a new page.
            if (al.*.size_classes[bin].alloc_pos == al.*.size_classes[bin].alloc_limit)
                addPage(al, bin);

            // Now we can allocate.
            result = @ptrCast(al.*.size_classes[bin].alloc_pos);
            al.*.size_classes[bin].alloc_pos += sizeOfBin(bin);
        }
    } else {
        // We're beyond the size class bins, so resort to malloc.
        result = c.MVM_malloc(size);

        // Add to overflows list.
        if (al.*.num_overflows == al.*.alloc_overflows) {
            al.*.alloc_overflows *%= 2;
            al.*.overflows = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(al.*.overflows), @as(usize, al.*.alloc_overflows) * @sizeOf([*c]Collectable))));
        }
        al.*.overflows[al.*.num_overflows] = @ptrCast(@alignCast(result));
        al.*.num_overflows +%= 1;
    }

    return result;
}

/// Allocates space using the second generation allocator and returns a
/// pointer to the allocated space. Promises the memory will be zeroed,
/// except that the MVMCollectable gen 2 flag will get set. (gen2.c:107-115)
pub fn allocateZeroed(al: Al, size: c.MVMuint32) callconv(.c) ?*anyopaque {
    const a = allocate(al, size);
    const bytes: [*c]u8 = @ptrCast(a);
    @memset(bytes[0..size], 0);
    @as([*c]Collectable, @ptrCast(@alignCast(a))).*.flags2 = c.MVM_CF_SECOND_GEN;
    return a;
}

/// Frees all memory associated with the second generation. (gen2.c:117-139)
pub fn destroy(i: [*c]c.MVMInstance, al: Al) callconv(.c) void {
    _ = i;
    var j: c.MVMuint32 = 0;

    // Remove all pages.
    while (j < BINS) : (j += 1) {
        var k: c.MVMuint32 = 0;
        while (k < al.*.size_classes[j].num_pages) : (k += 1)
            c.MVM_free(@ptrCast(al.*.size_classes[j].pages[k]));
        c.MVM_free(@ptrCast(al.*.size_classes[j].pages));
    }

    // Free any allocated overflows.
    j = 0;
    while (j < al.*.num_overflows) : (j += 1) {
        if (al.*.overflows[j] != null)
            c.MVM_free(@ptrCast(al.*.overflows[j]));
    }

    // Clean up allocator data structure.
    c.MVM_free(@ptrCast(al.*.size_classes));
    al.*.size_classes = null;
    c.MVM_free(@ptrCast(al.*.overflows));
    al.*.overflows = null;
    c.MVM_free(@ptrCast(al));
}

/// Blindly move pages from one gen2 to another. (gen2.c:141-267)
pub fn transfer(src: Tc, dest: Tc) callconv(.c) void {
    const gen2: Al = src.*.gen2;
    const dest_gen2: Al = dest.*.gen2;
    var obj_size: c.MVMuint32 = undefined;
    var freelist_insert_pos: FreelistPos = undefined;

    var bin: c.MVMuint32 = 0;
    while (bin < BINS) : (bin += 1) {
        const orig_dest_num_pages: c.MVMuint32 = dest_gen2.*.size_classes[bin].num_pages;
        var cur_ptr: [*c]u8 = undefined;
        var end_ptr: [*c]u8 = undefined;
        // If we've nothing allocated in this size class, skip it.
        if (gen2.*.size_classes[bin].pages == null)
            continue;

        if (dest_gen2.*.size_classes[bin].pages == null)
            dest_gen2.*.size_classes[bin].free_list = null;

        // Calculate object size for this bin.
        obj_size = sizeOfBin(bin);

        // freelist_insert_pos is a pointer to a memory location that stores
        // the address of the last traversed free list node (char **).
        // Initialize freelist insertion position to free list head.
        freelist_insert_pos = &gen2.*.size_classes[bin].free_list;

        if (dest_gen2.*.size_classes[bin].pages == null) {
            dest_gen2.*.size_classes[bin].pages = @ptrCast(@alignCast(c.MVM_malloc(@sizeOf(?*anyopaque) * @as(usize, gen2.*.size_classes[bin].num_pages))));
            dest_gen2.*.size_classes[bin].num_pages = gen2.*.size_classes[bin].num_pages;
        } else {
            dest_gen2.*.size_classes[bin].num_pages +%= gen2.*.size_classes[bin].num_pages;
            dest_gen2.*.size_classes[bin].pages = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(dest_gen2.*.size_classes[bin].pages), @sizeOf(?*anyopaque) * @as(usize, dest_gen2.*.size_classes[bin].num_pages))));
        }

        // Visit each page in the source.
        var page: c.MVMuint32 = 0;
        while (page < gen2.*.size_classes[bin].num_pages) : (page += 1) {
            // Visit all the objects, looking for dead ones and swap the
            // owner for each of them.
            cur_ptr = gen2.*.size_classes[bin].pages[page];
            end_ptr = if (page +% 1 == gen2.*.size_classes[bin].num_pages)
                gen2.*.size_classes[bin].alloc_pos
            else
                cur_ptr + obj_size *% PAGE_ITEMS;
            while (@intFromPtr(cur_ptr) < @intFromPtr(end_ptr)) {
                if (cur_ptr == @as([*c]u8, @ptrCast(freelist_insert_pos))) {
                    // skip
                } else if (cur_ptr == @as([*c]u8, @ptrCast(freelist_insert_pos.*))) {
                    freelist_insert_pos = @ptrCast(@alignCast(cur_ptr));
                } else { // note: we don't have tests that exercise this path yet.
                    @as([*c]Collectable, @ptrCast(@alignCast(cur_ptr))).*.owner = dest.*.thread_id;
                }

                // Move to the next object.
                cur_ptr += obj_size;
            }
            dest_gen2.*.size_classes[bin].pages[page +% orig_dest_num_pages] = gen2.*.size_classes[bin].pages[page];
        }

        freelist_insert_pos = &dest_gen2.*.size_classes[bin].free_list;
        while (freelist_insert_pos.* != null) {
            freelist_insert_pos = @ptrCast(@alignCast(freelist_insert_pos.*));
        }
        // chain the destination's freelist through any remaining unallocated area
        if (dest_gen2.*.size_classes[bin].alloc_pos != null) {
            cur_ptr = dest_gen2.*.size_classes[bin].alloc_pos;
            end_ptr = dest_gen2.*.size_classes[bin].alloc_limit;
            while (@intFromPtr(cur_ptr) < @intFromPtr(end_ptr)) {
                freelist_insert_pos.* = @ptrCast(@alignCast(cur_ptr));
                freelist_insert_pos = @ptrCast(@alignCast(cur_ptr));
                cur_ptr += obj_size;
            }
        }

        // link to the new pages, if any
        freelist_insert_pos.* = gen2.*.size_classes[bin].free_list;

        dest_gen2.*.size_classes[bin].alloc_pos = gen2.*.size_classes[bin].alloc_pos;
        dest_gen2.*.size_classes[bin].alloc_limit = gen2.*.size_classes[bin].alloc_limit;

        c.MVM_free(@ptrCast(gen2.*.size_classes[bin].pages));
        gen2.*.size_classes[bin].pages = null;
        gen2.*.size_classes[bin].num_pages = 0;
    }
    { // transfer the overflows
        if (gen2.*.num_overflows +% dest_gen2.*.num_overflows > dest_gen2.*.alloc_overflows) {
            dest_gen2.*.alloc_overflows = (if (gen2.*.alloc_overflows > dest_gen2.*.alloc_overflows)
                gen2.*.alloc_overflows
            else
                dest_gen2.*.alloc_overflows) *% 2; // double the larger of the 2 sizes
            dest_gen2.*.overflows = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(dest_gen2.*.overflows), @as(usize, dest_gen2.*.alloc_overflows) * @sizeOf([*c]Collectable))));
        }
        var i: c.MVMuint32 = 0;
        while (i < gen2.*.num_overflows) : (i += 1)
            gen2.*.overflows[i].*.owner = dest.*.thread_id;
        // memcpy(&dest_gen2->overflows[dest_gen2->num_overflows], gen2->overflows,
        //        gen2->num_overflows * sizeof(MVMCollectable *))
        const dest_at: [*c][*c]Collectable = &dest_gen2.*.overflows[dest_gen2.*.num_overflows];
        @memcpy(dest_at[0..gen2.*.num_overflows], gen2.*.overflows[0..gen2.*.num_overflows]);
        dest_gen2.*.num_overflows +%= gen2.*.num_overflows;

        gen2.*.num_overflows = 0;
        gen2.*.alloc_overflows = 0;
        c.MVM_free(@ptrCast(gen2.*.overflows));
        gen2.*.overflows = null;
    }
    { // copy the roots...
        const n: c.MVMuint32 = src.*.num_gen2roots;
        var i: c.MVMuint32 = 0;
        while (i < n) : (i += 1) {
            c.MVM_gc_root_gen2_add(dest, src.*.gen2roots[i]);
        }
        src.*.num_gen2roots = 0;
        src.*.alloc_gen2roots = 0;
        c.MVM_free(@ptrCast(src.*.gen2roots));
        src.*.gen2roots = null;
    }
}

/// Compact the overflow list to prevent it from growing without bounds.
/// (gen2.c:270-291)
pub fn compactOverflows(al: Al) callconv(.c) void {
    const overflows: [*c][*c]Collectable = al.*.overflows;
    const num_overflows: c.MVMuint32 = al.*.num_overflows;
    var cursor: c.MVMuint32 = 0;
    var live: c.MVMuint32 = undefined;

    // Find the first NULL object.
    while (cursor < num_overflows and overflows[cursor] != null)
        cursor += 1;
    live = cursor;

    // Slide others back so the alive ones are at the start of the list.
    while (cursor < num_overflows) {
        if (overflows[cursor] != null) {
            overflows[live] = overflows[cursor];
            live += 1;
        }
        cursor += 1;
    }

    al.*.num_overflows = live;
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.builtin.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&create, .{ .name = "MVM_gc_gen2_create", .visibility = visibility });
    @export(&allocate, .{ .name = "MVM_gc_gen2_allocate", .visibility = visibility });
    @export(&allocateZeroed, .{ .name = "MVM_gc_gen2_allocate_zeroed", .visibility = visibility });
    @export(&destroy, .{ .name = "MVM_gc_gen2_destroy", .visibility = visibility });
    @export(&transfer, .{ .name = "MVM_gc_gen2_transfer", .visibility = visibility });
    @export(&compactOverflows, .{ .name = "MVM_gc_gen2_compact_overflows", .visibility = visibility });
}
