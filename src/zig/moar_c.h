/* Entry point for translate-c (build/zig/zigimpl.zig). Zig cannot express
 * C11 _Atomic types; MoarVM uses them only for word-sized counters whose
 * size and alignment equal the plain type on every supported target, and
 * Zig code never touches those fields directly. The shim unit tests check
 * the resulting struct layouts against the C compiler. */
#define _Atomic(T) T
#include "moar.h"
