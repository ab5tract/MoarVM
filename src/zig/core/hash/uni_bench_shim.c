/* Compiled into the uni-bench executable with libmoar's flags and config.h:
 * out-of-line wrappers of the MVM_uni_hash_* functions the unicode
 * benchmark times, as bench_shim.c does for the string table, so both
 * engines pay one identical call per lookup. */
#include "moar.h"

void *bench_uni_fetch(MVMThreadContext *tc, MVMUniHashTable *hashtable, const char *key) {
    return MVM_uni_hash_fetch(tc, hashtable, key);
}
void bench_uni_insert(MVMThreadContext *tc, MVMUniHashTable *hashtable, const char *key, MVMint32 value) {
    MVM_uni_hash_insert(tc, hashtable, key, value);
}
void bench_uni_demolish(MVMThreadContext *tc, MVMUniHashTable *hashtable) {
    MVM_uni_hash_demolish(tc, hashtable);
}
