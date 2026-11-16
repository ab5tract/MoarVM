# The VMArray differential program for the two devirtualized functions (spec
# traces/llm/specs/2026-11-16-zig-vmarray-repr-design.md, section 7 item 2).
#
# src/6model/reprs/VMArray.c hands the JIT two functions of its own,
# vmarray_at_pos_int64 and vmarray_bind_pos_int64, through
# MVM_VMArray_find_fast_impl_for_jit; compiled code calls them for
# atpos_i/bindpos_i on an array it knows to be I64 (and atpos_u/bindpos_u on
# one it knows to be U64). Each raises "MVMArray: Index out of bounds" itself.
# Whether a given call is compiled that way depends on what the specializer
# knows where the call is compiled. The hot loops of vmarray-diff.nqp run the
# two functions, but none of the shapes tried there ends in their errors
# (measured with breakpoints on both, traces/llm/bench/va-differential.md);
# this program is the one shape found that does, with MVM_SPESH_BLOCKING=1 and
# without: the mainline calls each wrapper a thousand times in a loop, and the
# calls that count follow in the same mainline frame. Do not reshape it
# without measuring again.
#
# Output as in vmarray-diff.nqp: `<case name>: <result>`, or
# `<case name>: DIED <message>`. With MVM_SPESH_DISABLE=1 the same lines come
# from MVM_VMArray_at_pos and MVM_VMArray_bind_pos.
#
# Run: <prefix>/bin/nqp-m tools/bench/repr/vmarray-devirt.nqp

sub known_at_i($ty, int $rounds, int $bad) {
    my $a := nqp::create($ty);
    nqp::setelems($a, 10);
    my int $sum := 0;
    my int $i := 0;
    while $i < $rounds { $sum := $sum + nqp::atpos_i($a, $i == $rounds - 1 ?? $bad !! $i % 10); $i++ }
    $sum
}
sub known_bind_i($ty, int $rounds, int $bad) {
    my $a := nqp::create($ty);
    nqp::setelems($a, 10);
    my int $i := 0;
    while $i < $rounds { nqp::bindpos_i($a, $i == $rounds - 1 ?? $bad !! $i % 10, $i); $i++ }
    nqp::elems($a)
}
my $ty := nqp::what(nqp::list_i());
my int $said := 0;
sub once_at($name, int $bad) { try { my $r := known_at_i($ty, 2000, $bad); say("$name: $r") if $said; CATCH { say("$name: DIED " ~ nqp::getmessage($!)) } } }
sub once_bind($name, int $bad) { try { my $r := known_bind_i($ty, 2000, $bad); say("$name: $r") if $said; CATCH { say("$name: DIED " ~ nqp::getmessage($!)) } } }
my int $q := 0;
while $q < 1000 { once_at('a', -1); once_bind('b', -1); $q++ }
$said := 1;
once_at('i64.devirt.at_i.-11', -11);
once_bind('i64.devirt.bind_i.-11', -11);
once_at('i64.devirt.at_i.-11.again', -11);
once_bind('i64.devirt.bind_i.-11.again', -11);
once_at('i64.devirt.at_i.-10', -10);
once_bind('i64.devirt.bind_i.-10', -10);
once_at('i64.devirt.at_i.10', 10);
once_bind('i64.devirt.bind_i.10', 10);
once_bind('i64.devirt.bind_i.30000', 30000);
say('done: 1');
