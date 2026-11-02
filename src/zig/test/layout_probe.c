/* Compiled into the shim unit tests with libmoar's flags: the C compiler's
 * view of struct layouts, to compare with translate-c's. */
#include "moar.h"
#include <stddef.h>
size_t moar_probe_sizeof_tc(void) { return sizeof(MVMThreadContext); }
size_t moar_probe_sizeof_instance(void) { return sizeof(MVMInstance); }
size_t moar_probe_offsetof_num_temproots(void) { return offsetof(MVMThreadContext, num_temproots); }
size_t moar_probe_offsetof_int_const_cache(void) { return offsetof(MVMInstance, int_const_cache); }
size_t moar_probe_offsetof_object_st(void) { return offsetof(MVMObject, st); }
