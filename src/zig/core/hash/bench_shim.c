/* Compiled into the hash-bench executable with libmoar's flags and config.h:
 * one out-of-line wrapper per MVM_str_hash_* function the benchmark times.
 * With MVM_ZIG_IMPL off most of these are inline C in the headers, so this
 * is the only way the benchmark can call the compiled C engine; with it on
 * they resolve to the Zig exports in libmoar. Both engines then pay one
 * identical wrapper call per operation, which cancels in the ratio. */
#include "moar.h"

void bench_str_build(MVMThreadContext *tc, MVMStrHashTable *ht, MVMuint32 entry_size, MVMuint32 entries) {
    MVM_str_hash_build(tc, ht, entry_size, entries);
}
void bench_str_demolish(MVMThreadContext *tc, MVMStrHashTable *ht) {
    MVM_str_hash_demolish(tc, ht);
}
size_t bench_str_allocated_size(MVMThreadContext *tc, MVMStrHashTable *ht) {
    return MVM_str_hash_allocated_size(tc, ht);
}
void *bench_str_lvalue_fetch_nocheck(MVMThreadContext *tc, MVMStrHashTable *ht, MVMString *key) {
    return MVM_str_hash_lvalue_fetch_nocheck(tc, ht, key);
}
void *bench_str_fetch_nocheck(MVMThreadContext *tc, MVMStrHashTable *ht, MVMString *key) {
    return MVM_str_hash_fetch_nocheck(tc, ht, key);
}
void bench_str_delete_nocheck(MVMThreadContext *tc, MVMStrHashTable *ht, MVMString *key) {
    MVM_str_hash_delete_nocheck(tc, ht, key);
}
MVMStrHashIterator bench_str_first(MVMThreadContext *tc, MVMStrHashTable *ht) {
    return MVM_str_hash_first(tc, ht);
}
MVMStrHashIterator bench_str_next_nocheck(MVMThreadContext *tc, MVMStrHashTable *ht, MVMStrHashIterator it) {
    return MVM_str_hash_next_nocheck(tc, ht, it);
}
void *bench_str_current_nocheck(MVMThreadContext *tc, MVMStrHashTable *ht, MVMStrHashIterator it) {
    return MVM_str_hash_current_nocheck(tc, ht, it);
}
int bench_str_at_end(MVMThreadContext *tc, MVMStrHashTable *ht, MVMStrHashIterator it) {
    return MVM_str_hash_at_end(tc, ht, it);
}
