/* The layout strategy each of MoarVM's internal hash tables is built with
 * (docs/hash-strategies.md). One macro per assignment site; a site builds with
 * MVM_<kind>_hash_build_strategy(..., MVM_HASH_INTERNAL_<SITE>) so changing a
 * site is changing one line here. The C engine knows only the default, and
 * its build_strategy throws for anything else, so a site may name another
 * strategy only under MVM_ZIG_IMPL. Measurements:
 * traces/llm/bench/internals-*.md. */

/* The unicode tables (src/strings/unicode_ops.c, unicode_db.c). Swiss
 * (MVM_HASH_STRATEGY_LOOKUP) was measured for all four on the unicode
 * benchmark and won none of them (internals-uni-bench.md), so each stays on
 * the default; the explicit build still gives each table its real size up
 * front. To try Swiss again: `#if MVM_ZIG_IMPL` ... LOOKUP ... `#else`
 * DEFAULT, per site. */
#define MVM_HASH_INTERNAL_UNI_PROPERTY_CODES MVM_HASH_STRATEGY_DEFAULT
#define MVM_HASH_INTERNAL_UNI_SEQ_NAMES MVM_HASH_STRATEGY_DEFAULT
#define MVM_HASH_INTERNAL_UNI_CODEPOINTS MVM_HASH_STRATEGY_DEFAULT
/* One property-value table, given its entry count n (the choice is per build
 * call, not per site). */
#define MVM_HASH_INTERNAL_UNI_PROPERTY_VALUES(n) MVM_HASH_STRATEGY_DEFAULT
