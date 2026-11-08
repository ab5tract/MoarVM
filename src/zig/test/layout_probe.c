/* Compiled into the shim unit tests with libmoar's flags: the C compiler's
 * view of struct layouts, to compare with translate-c's. */
#include "moar.h"
#include <stddef.h>
size_t moar_probe_sizeof_tc(void) { return sizeof(MVMThreadContext); }
size_t moar_probe_sizeof_instance(void) { return sizeof(MVMInstance); }
size_t moar_probe_offsetof_num_temproots(void) { return offsetof(MVMThreadContext, num_temproots); }
size_t moar_probe_offsetof_int_const_cache(void) { return offsetof(MVMInstance, int_const_cache); }
size_t moar_probe_offsetof_object_st(void) { return offsetof(MVMObject, st); }
/* MVMDebugServerData is opaque to translate-c (bit-fields); orchestrate.zig
 * mirrors it and checks these against its mirror. */
size_t moar_probe_sizeof_debugserver(void) { return sizeof(MVMDebugServerData); }
size_t moar_probe_offsetof_debugserver_mutex_cond(void) { return offsetof(MVMDebugServerData, mutex_cond); }
size_t moar_probe_offsetof_debugserver_tell_threads(void) { return offsetof(MVMDebugServerData, tell_threads); }
size_t moar_probe_offsetof_debugserver_request_data(void) { return offsetof(MVMDebugServerData, request_data); }
size_t moar_probe_offsetof_debugserver_debugspam_protocol(void) { return offsetof(MVMDebugServerData, debugspam_protocol); }
/* The worklist.h macro the Zig worklist tests check against (translate-c
 * cannot translate its do/while body). */
void moar_probe_worklist_add_include_gen2_nocheck(MVMThreadContext *tc, MVMGCWorklist *worklist, MVMCollectable **item) {
    MVM_gc_worklist_add_include_gen2_nocheck(tc, worklist, item);
}
