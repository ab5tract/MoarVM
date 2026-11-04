#include "moar.h"

#if MVM_GC_DEBUG
/* Takes a pointer of a GC-allocated object, and goes through all of the
 * alive thread's fromspace/tospace regions and all gen2 pages to try and
 * find the region the pointer is part of. */
void MVM_gc_debug_find_region(MVMThreadContext *tc, void *ptr) {
    MVMThread *cur_thread = tc->instance->threads;
    while (cur_thread) {
        MVMThreadContext *thread_tc = cur_thread->body.tc;
        if (thread_tc) {
            if (ptr >= thread_tc->nursery_fromspace &&
                    (char *)ptr < (char *)thread_tc->nursery_fromspace +
                        thread_tc->nursery_fromspace_size) {
                printf("In fromspace of thread %d\n", cur_thread->body.thread_id);
                return;
            }
            if (ptr >= thread_tc->nursery_tospace &&
                    (char *)ptr < (char *)thread_tc->nursery_tospace +
                        thread_tc->nursery_tospace_size) {
                printf("In tospace of thread %d\n", cur_thread->body.thread_id);
                return;
            }
            if (thread_tc->gen2) {
                MVMGen2Allocator *gen2 = thread_tc->gen2;
                MVMint32 bin;
                for (bin = 0; bin < MVM_GEN2_BINS; bin++) {
                    MVMGen2SizeClass *szc = &(gen2->size_classes[bin]);
                    MVMuint32 page;
                    for (page = 0; page < szc->num_pages; page++) {
                        char *page_start = szc->pages[page];
                        size_t page_size = MVM_GEN2_PAGE_ITEMS * ((bin + 1) << MVM_GEN2_BIN_BITS);
                        char *page_end = page_start + page_size;
                        if (ptr >= (void*)page_start && ptr < (void*)page_end) {
                            printf("In gen2 bin of thread %d\n", cur_thread->body.thread_id);
                            return;
                        }
                    }
                }
            }
        }
        cur_thread = cur_thread->body.next;
    }
    printf("Not found\n");
}

/* Writes one line of the per-collection log ($MVM_GC_LOG) for the run that
 * tc has just finished on behalf of for_tc, then resets for_tc's counters.
 * coord is 1 for the thread that started the run. */
void MVM_gc_debug_log_collection(MVMThreadContext *tc, MVMThreadContext *for_tc, MVMuint8 full) {
    FILE *log = tc->instance->gc_debug_log;
    if (log) {
        fprintf(log,
            "seq=%"PRIu64" tid=%"PRIu32" full=%d coord=%d from=%"PRIu32" next=%"PRIu32
            " promoted=%"PRIu32" since_full=%"PRIu64" gen2_freed=%"PRIu64
            " stables_freed=%"PRIu32" finalizing=%"PRIu32"\n",
            (MVMuint64)MVM_load(&tc->instance->gc_seq_number),
            (MVMuint32)for_tc->thread_id,
            full ? 1 : 0,
            for_tc == tc->instance->thread_to_blame_for_gc ? 1 : 0,
            for_tc->nursery_fromspace_size,
            for_tc->nursery_tospace_size,
            for_tc->gc_promoted_bytes,
            (MVMuint64)MVM_load(&tc->instance->gc_promoted_bytes_since_last_full),
            for_tc->gc_debug_gen2_freed_bytes,
            for_tc->gc_debug_stables_freed,
            for_tc->num_finalizing);
        fflush(log);
    }
    for_tc->gc_debug_gen2_freed_bytes = 0;
    for_tc->gc_debug_stables_freed = 0;
}
#endif
