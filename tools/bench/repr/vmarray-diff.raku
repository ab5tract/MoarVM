# The VMArray differential program, Raku half (spec
# traces/llm/specs/2026-11-16-zig-vmarray-repr-design.md, section 7 item 2).
#
# Reaches what the nqp half (vmarray-diff.nqp) cannot: native references to
# array positions (nqp::atposref_*, nqp::multidimref_*), the atomic operations
# on a position (pos_as_atomic, pos_as_atomic_multidim), and the arrays as
# Rakudo uses them: array[int8] to array[uint64], array[num32], array[num64],
# array[str], buf8 to buf64, blob8, and the VMArray inside an Array (its
# reified IterationBuffer). Every output line is
#     <case name>: <result>
# and a caught exception prints
#     <case name>: DIED <message>
# Nothing in the output varies from run to run. tools/bench/repr/diff.sh runs
# it on two builds and compares the output byte for byte.
#
# Run: RAKUDO_NO_PRECOMPILATION=1 <rakudo>/rakudo-m tools/bench/repr/vmarray-diff.raku

use nqp;

sub t(Str $name, &code) {
    my $r;
    try {
        # A Failure is an exception not yet thrown: print it as one, and mark
        # it handled so that no warning is left for its DESTROY.
        my \v = code();
        if v ~~ Failure { v.so; $r = 'DIED ' ~ v.exception.message } else { $r = v }
        CATCH { default { $r = 'DIED ' ~ .message } }
    }
    $r = '<undefined>' without $r;
    say "$name: " ~ $r.Str.subst("\n", ' | ', :g);
}

sub d(\a) { 'elems=' ~ a.elems ~ ' [' ~ a.list.join(' ') ~ ']' }
sub dbig(\a) {
    a.elems <= 40
        ?? d(a)
        !! 'elems=' ~ a.elems ~ ' sha1=' ~ nqp::sha1(a.list.join(' ')) ~ ' head=[' ~ a[^3].join(' ') ~ '] tail=[' ~ a[*-3..*].join(' ') ~ ']'
}

my @int-types  = int8, int16, int32, int64, uint8, uint16, uint32, uint64;
my @num-types  = num32, num64;
my @special    = 0, 1, -1, 127, 128, 255, 256, -128, -129, 32767, 32768, 65535, 65536, -32768, -32769,
                 2147483647, 2147483648, 4294967295, 4294967296, -2147483648, -2147483649,
                 9223372036854775807, 9223372036854775808, -9223372036854775808, -9223372036854775809,
                 18446744073709551615, 18446744073709551616;

# ---------------------------------------------------------- native int arrays

for @int-types -> \T {
    my $n = T.^name;
    my $unsigned = $n.starts-with('u');
    my sub fresh(*@v) { my $a := array[T].new; $a.push($_) for @v; $a }
    my sub shifted(*@v) { my $a := array[T].new(90, 91, 92); $a.push($_) for @v; $a.shift xx 3; $a }

    t "$n.type",            { my $a := fresh(); nqp::reprname($a) ~ ' ' ~ $a.^name ~ ' ' ~ nqp::objprimspec(T) ~ ' ' ~ nqp::objprimbits(T) ~ ' ' ~ nqp::objprimunsigned(T) };
    t "$n.empty.elems",     { my $a := fresh(); $a.elems ~ ' ' ~ $a.Bool ~ ' ' ~ nqp::elems($a) ~ ' ' ~ nqp::istrue($a) };
    t "$n.empty.at0",       { my $a := fresh(); $a[0] ~ ' ' ~ $a[5] ~ ' ' ~ $a.elems };
    t "$n.empty.at-1",      { my $a := fresh(); $a[*-1] };
    t "$n.empty.nqp.at-1",  { my $a := fresh(); nqp::atpos_i($a, -1) };
    t "$n.empty.pop",       { fresh().pop };
    t "$n.empty.shift",     { fresh().shift };
    t "$n.empty.nqp.pop",   { nqp::pop_i(fresh()) };
    t "$n.empty.nqp.shift", { nqp::shift_i(fresh()) };
    t "$n.push",            { my $a := fresh(); $a.push($_) for ^20; d($a) };
    t "$n.push.list",       { my $a := fresh(1, 2); $a.push(3, 4, 5); $a.append(6, 7); $a.append(fresh(8, 9)); d($a) };
    t "$n.pop",             { my $a := fresh(^10); $a.pop ~ ' ' ~ $a.pop ~ ' ' ~ d($a) };
    t "$n.shift",           { my $a := fresh(^10); $a.shift ~ ' ' ~ $a.shift ~ ' ' ~ d($a) };
    t "$n.unshift",         { my $a := fresh(^5); $a.unshift(9); $a.unshift(8, 7); $a.prepend(6, 5); $a.prepend(fresh(4, 3)); d($a) };
    t "$n.unshift.many",    { my $a := fresh(); $a.unshift($_ % 100) for ^300; dbig($a) };
    t "$n.queue",           { my $a := fresh(); my $s = 0; for ^500 { $a.push($_ % 100); $a.push(1); $s += $a.shift }; $s ~ ' ' ~ dbig($a) };
    t "$n.stack",           { my $a := fresh(); my $s = 0; for ^500 { $a.unshift($_ % 100); $a.unshift(1); $s += $a.pop }; $s ~ ' ' ~ dbig($a) };
    t "$n.assign",          { my $a := fresh(^5); $a[2] = 9; $a[*-1] = 8; $a[7] = 7; d($a) };
    t "$n.assign.neg",      { my $a := fresh(^5); $a[*-6] = 9; d($a) };
    t "$n.nqp.bind.neg",    { my $a := fresh(^5); nqp::bindpos_i($a, -5, 9); nqp::bindpos_i($a, -1, 8); d($a) };
    t "$n.nqp.bind.oob",    { my $a := fresh(^5); nqp::bindpos_i($a, -6, 9); d($a) };
    t "$n.nqp.at",          { my $a := fresh(^5); nqp::atpos_i($a, 0) ~ ' ' ~ nqp::atpos_i($a, -1) ~ ' ' ~ nqp::atpos_i($a, -5) ~ ' ' ~ nqp::atpos_i($a, 5) };
    t "$n.nqp.at.oob",      { my $a := fresh(^5); nqp::atpos_i($a, -6) };
    t "$n.nqp.at_u",        { my $a := fresh(^5); nqp::bindpos_i($a, 0, -1); my uint $u = nqp::atpos_u($a, 0); $u };
    t "$n.nqp.bind_u",      { my $a := fresh(^5); my uint $u = 18446744073709551615; nqp::bindpos_u($a, 1, $u); d($a) };
    t "$n.nqp.wrongkind",   { my $a := fresh(^5); nqp::atpos_n($a, 0) };
    t "$n.nqp.wrongkind.s", { my $a := fresh(^5); nqp::atpos_s($a, 0) };
    t "$n.nqp.wrongkind.o", { my $a := fresh(^5); nqp::isnull(nqp::atpos($a, 0)) };
    t "$n.nqp.push.wrong",  { my $a := fresh(^5); nqp::push_n($a, 1e0); d($a) };
    t "$n.nqp.push.wrong.after", { my $a := fresh(^5); try nqp::push_s($a, 'x'); try nqp::pop_n($a); try nqp::unshift_n($a, 1e0); d($a) };
    t "$n.elems.set",       { my $a := fresh(^5); nqp::setelems($a, 8); my $r = d($a); nqp::setelems($a, 2); nqp::setelems($a, 4); $r ~ ' / ' ~ d($a) };
    t "$n.elems.limit",     { my $a := fresh(^5); nqp::setelems($a, -1); d($a) };
    t "$n.list.assign",     { my $a := fresh(^5); $a = (7, 8, 9); my $r = d($a); $a = (); $r ~ ' / ' ~ d($a) };
    t "$n.list.assign.self", { my $a := fresh(^5); $a = $a.reverse; d($a) };
    t "$n.slice",           { my $a := fresh(^10); $a[1..3].join(' ') ~ ' / ' ~ $a[*-2..*].join(' ') ~ ' / ' ~ $a[7..12].join(' ') ~ ' / ' ~ $a[3, 1, 9].join(' ') };
    t "$n.slice.assign",    { my $a := fresh(^10); $a[1..3] = 21, 22, 23; $a[12, 14] = 5, 6; d($a) };
    t "$n.nqp.slice",       { my $a := shifted(^10); my $s := nqp::slice($a, 2, -3); $s.push(7); d($s) ~ ' ' ~ $s.^name ~ ' / ' ~ d($a) };
    t "$n.nqp.slice.oob",   { my $a := fresh(^10); d(nqp::slice($a, 5, 10)) };
    t "$n.clone",           { my $a := shifted(^6); my $c := $a.clone; $c.push(7); $a.shift; d($c) ~ ' / ' ~ d($a) };
    t "$n.exists",          { my $a := fresh(^3); ($a[0]:exists) ~ ' ' ~ ($a[2]:exists) ~ ' ' ~ ($a[3]:exists) ~ ' ' ~ ($a[*-1]:exists) };
    t "$n.delete",          { my $a := fresh(^3); $a[1]:delete };
    t "$n.iterate",         { my $a := shifted(^6); my $s = 0; $s += $_ for $a; $s ~ ' ' ~ $a.map(* + 1).join(' ') ~ ' ' ~ $a.reverse.join(' ') ~ ' ' ~ $a.sum ~ ' ' ~ $a.kv.join(' ') };
    t "$n.join",            { my $a := shifted(^6); $a.join(',') ~ ' ' ~ $a.Str ~ ' ' ~ $a.gist ~ ' ' ~ $a.raku };
    t "$n.sort",            { my $a := fresh(5, 3, 9, 1, 7); $a.sort.join(' ') ~ ' ' ~ $a.min ~ ' ' ~ $a.max ~ ' ' ~ $a.grep(* > 3).join(' ') };
    t "$n.eqv",             { my $a := fresh(^4); my $b := shifted(^4); ($a eqv $b) ~ ' ' ~ ($a eqv fresh(^5)) };
    t "$n.flatten",         { my $a := shifted(^4); (sub (*@x) { @x.join(',') })(|$a) ~ ' ' ~ (sub ($p, $q, $r, $s) { "$p$q$r$s" })(|$a) };

    for (
        'insert.front',   (0, 0, (7, 8)),      'insert.middle', (3, 0, (7, 8)),
        'insert.end',     (6, 0, (7, 8)),      'delete.front',  (0, 2, ()),
        'delete.middle',  (2, 2, ()),          'delete.tail',   (4, 2, ()),
        'delete.all',     (0, 6, ()),          'delete.over',   (2, 9, ()),
        'replace.same',   (1, 2, (7, 8)),      'replace.shorter', (1, 4, (7, 8)),
        'replace.longer', (1, 1, (7, 8, 9)),   'replace.front', (0, 3, (7, 8, 9, 10, 11)),
        'none',           (2, 0, ()),
    ) -> $name, ($off, $cnt, $new) {
        t "$n.splice.$name",         { my $a := fresh(^6);   my $r := $a.splice($off, $cnt, @$new); d($r) ~ ' / ' ~ d($a) };
        t "$n.splice.$name.shifted", { my $a := shifted(^6); my $r := $a.splice($off, $cnt, @$new); d($r) ~ ' / ' ~ d($a) };
    }
    t "$n.splice.past",     { my $a := fresh(^6); $a.splice(8, 0, (1,)); d($a) };
    t "$n.splice.neg",      { my $a := fresh(^6); $a.splice(*-2, 1, (1, 2)); d($a) };
    t "$n.splice.whatever", { my $a := fresh(^6); $a.splice(2); d($a) };
    t "$n.splice.native",   { my $a := fresh(^6); $a.splice(2, 1, fresh(7, 8)); d($a) };
    t "$n.splice.self",     { my $a := fresh(^6); $a.splice(2, 1, $a); d($a) };
    t "$n.nqp.splice",      { my $a := fresh(^6); nqp::splice($a, shifted(7, 8, 9), 1, 2); d($a) };
    t "$n.nqp.splice.self", { my $a := fresh(^6); nqp::splice($a, $a, 3, 0); d($a) };
    t "$n.nqp.splice.self.front", { my $a := shifted(^6); nqp::splice($a, $a, 0, 2); d($a) };
    t "$n.nqp.splice.oob",  { my $a := fresh(^6); nqp::splice($a, fresh(1), -7, 0); d($a) };
    for @int-types -> \S {
        my $sn = S.^name;
        t "$n.nqp.splice.from.$sn", { my $a := fresh(^4); my $s := array[S].new(-1, 300, 70000, 5000000000); nqp::splice($a, $s, 1, 1); d($a) };
    }
    t "$n.nqp.splice.from.num64", { my $a := fresh(^4); nqp::splice($a, array[num64].new(1.5e0, -2e0), 1, 1); d($a) };
    t "$n.nqp.splice.from.num32", { my $a := fresh(^4); nqp::splice($a, array[num32].new(1.5e0, -2e0), 1, 1); d($a) };

    # Review Focus 2: every write path with values at and around the limits.
    for @special -> $v {
        t "$n.value.$v", {
            my $a := fresh();
            my @r;
            @r.push: (try { $a[0] = $v; 'assign=' ~ $a[0] }) // 'assign DIED ' ~ $!.message;
            @r.push: (try { $a.push($v); 'push=' ~ $a[*-1] }) // 'push DIED ' ~ $!.message;
            @r.push: (try { $a.unshift($v); 'unshift=' ~ $a[0] }) // 'unshift DIED ' ~ $!.message;
            @r.push: (try { my $b := array[T].new($v); 'new=' ~ $b[0] ~ ' pop=' ~ $b.pop }) // 'new DIED ' ~ $!.message;
            @r.push: (try { my $b := array[T].new($v); 'shift=' ~ $b.shift }) // 'shift DIED ' ~ $!.message;
            @r.push: (try { $a.splice(0, 0, ($v,)); 'splice=' ~ $a[0] }) // 'splice DIED ' ~ $!.message;
            @r.push: 'elems=' ~ $a.elems;
            @r.join(' ')
        };
    }
    for 0, 1, -1, 127, 128, 255, 256, -129, 32768, 65535, -32769, 2147483648, 4294967295, -2147483649, 9223372036854775807 -> int $v {
        t "$n.nqp.value.$v", {
            my $a := fresh();
            nqp::bindpos_i($a, 0, $v); nqp::push_i($a, $v); nqp::unshift_i($a, $v);
            my $r = (^3).map({ nqp::atpos_i($a, $_) }).join(' ') ~ ' / ' ~ $a.list.join(' ');
            $r ~ ' / ' ~ nqp::pop_i($a) ~ ' ' ~ nqp::shift_i($a) ~ ' ' ~ $a[0]
        };
    }

    # Native references to positions.
    t "$n.ref.read",        { my $a := shifted(5, 6, 7); my $r := $unsigned ?? nqp::atposref_u($a, 1) !! nqp::atposref_i($a, 1); $r ~ ' ' ~ $r.^name };
    t "$n.ref.write",       { my $a := shifted(5, 6, 7); my $r := $unsigned ?? nqp::atposref_u($a, 1) !! nqp::atposref_i($a, 1); $r = 9; $r++; d($a) };
    t "$n.ref.neg",         { my $a := shifted(5, 6, 7); my $r := $unsigned ?? nqp::atposref_u($a, -1) !! nqp::atposref_i($a, -1); $r = $r + 1; d($a) };
    t "$n.ref.past.read",   { my $a := shifted(5, 6, 7); my $r := $unsigned ?? nqp::atposref_u($a, 5) !! nqp::atposref_i($a, 5); $r ~ ' ' ~ d($a) };
    t "$n.ref.past.write",  { my $a := shifted(5, 6, 7); my $r := $unsigned ?? nqp::atposref_u($a, 5) !! nqp::atposref_i($a, 5); $r = 3; d($a) };
    t "$n.ref.oob.read",    { my $a := shifted(5, 6, 7); my $r := $unsigned ?? nqp::atposref_u($a, -4) !! nqp::atposref_i($a, -4); $r + 0 };
    t "$n.ref.oob.write",   { my $a := shifted(5, 6, 7); my $r := $unsigned ?? nqp::atposref_u($a, -4) !! nqp::atposref_i($a, -4); $r = 1; d($a) };
    t "$n.ref.wrong.i",     { my $a := shifted(5, 6, 7); my $r := nqp::atposref_i($a, 0); $r + 0 };
    t "$n.ref.wrong.u",     { my $a := shifted(5, 6, 7); my $r := nqp::atposref_u($a, 0); $r + 0 };
    t "$n.ref.wrong.n",     { my $a := shifted(5, 6, 7); my $r := nqp::atposref_n($a, 0); $r + 0 };
    t "$n.ref.wrong.s",     { my $a := shifted(5, 6, 7); my $r := nqp::atposref_s($a, 0); $r ~ '' };
    t "$n.ref.wrong.n.write", { my $a := shifted(5, 6, 7); my $r := nqp::atposref_n($a, 0); $r = 1e0; d($a) };
    t "$n.ref.stale",       { my $a := shifted(5, 6, 7); my $r := $unsigned ?? nqp::atposref_u($a, 2) !! nqp::atposref_i($a, 2); $a.shift; $a.pop; $r ~ ' ' ~ d($a) };
    t "$n.ref.postfix",     { my $a := shifted(5, 6, 7); $a[0]++; $a[1] += 10; $a[2] *= 2; ++$a[5]; d($a) };
    t "$n.mdref.read",      { my $a := shifted(5, 6, 7); my $r := $unsigned ?? nqp::multidimref_u($a, nqp::list_i(1)) !! nqp::multidimref_i($a, nqp::list_i(1)); $r + 0 };
    t "$n.mdref.write",     { my $a := shifted(5, 6, 7); my $r := $unsigned ?? nqp::multidimref_u($a, nqp::list_i(1)) !! nqp::multidimref_i($a, nqp::list_i(1)); $r = 9; d($a) };
    t "$n.mdref.2",         { my $a := shifted(5, 6, 7); my $r := $unsigned ?? nqp::multidimref_u($a, nqp::list_i(0, 1)) !! nqp::multidimref_i($a, nqp::list_i(0, 1)); $r + 0 };
    t "$n.mdref.2.write",   { my $a := shifted(5, 6, 7); my $r := $unsigned ?? nqp::multidimref_u($a, nqp::list_i(0, 1)) !! nqp::multidimref_i($a, nqp::list_i(0, 1)); $r = 1; d($a) };
    t "$n.mdref.oob",       { my $a := shifted(5, 6, 7); my $r := $unsigned ?? nqp::multidimref_u($a, nqp::list_i(-9)) !! nqp::multidimref_i($a, nqp::list_i(-9)); $r + 0 };

    # The atomic operations on a position.
    # (An unsigned reference is refused by the atomic operations before they
    # reach the array, so the unsigned kinds go through an int reference too.)
    my sub ref(\a, $i) is raw { nqp::atposref_i(a, $i) }
    t "$n.atomic.load",     { my $a := shifted(5, 6, 7); nqp::atomicload_i(ref($a, 1)) };
    t "$n.atomic.load.neg", { my $a := shifted(5, 6, 7); nqp::atomicload_i(ref($a, -1)) ~ ' ' ~ nqp::atomicload_i(ref($a, -3)) };
    t "$n.atomic.load.past", { my $a := shifted(5, 6, 7); nqp::atomicload_i(ref($a, 3)) };
    t "$n.atomic.load.oob", { my $a := shifted(5, 6, 7); nqp::atomicload_i(ref($a, -4)) };
    t "$n.atomic.load.empty", { my $a := fresh(); nqp::atomicload_i(ref($a, 0)) };
    t "$n.atomic.store",    { my $a := shifted(5, 6, 7); nqp::atomicstore_i(ref($a, 1), 9); d($a) };
    t "$n.atomic.store.past", { my $a := shifted(5, 6, 7); nqp::atomicstore_i(ref($a, 3), 9); d($a) };
    t "$n.atomic.cas.hit",  { my $a := shifted(5, 6, 7); nqp::cas_i(ref($a, 1), 6, 9) ~ ' ' ~ d($a) };
    t "$n.atomic.cas.miss", { my $a := shifted(5, 6, 7); nqp::cas_i(ref($a, 1), 5, 9) ~ ' ' ~ d($a) };
    t "$n.atomic.cas.oob",  { my $a := shifted(5, 6, 7); nqp::cas_i(ref($a, 7), 0, 9) ~ ' ' ~ d($a) };
    t "$n.atomic.inc",      { my $a := shifted(5, 6, 7); nqp::atomicinc_i(ref($a, 0)) ~ ' ' ~ nqp::atomicinc_i(ref($a, 0)) ~ ' ' ~ d($a) };
    t "$n.atomic.dec",      { my $a := shifted(5, 6, 7); nqp::atomicdec_i(ref($a, 2)) ~ ' ' ~ d($a) };
    t "$n.atomic.add",      { my $a := shifted(5, 6, 7); nqp::atomicadd_i(ref($a, -1), 100) ~ ' ' ~ d($a) };
    t "$n.atomic.max",      { my $a := shifted(5, 6, 7); nqp::atomicstore_i(ref($a, 0), 9223372036854775807); nqp::atomicinc_i(ref($a, 0)) ~ ' ' ~ $a[0] };
    my sub mdref(\a, *@i) is raw { my $l := nqp::list_i(); nqp::push_i($l, $_) for @i; nqp::multidimref_i(a, $l) }
    t "$n.atomic.md.load",  { my $a := shifted(5, 6, 7); nqp::atomicload_i(mdref($a, 1)) ~ ' ' ~ nqp::atomicload_i(mdref($a, -1)) };
    t "$n.atomic.md.cas",   { my $a := shifted(5, 6, 7); nqp::cas_i(mdref($a, 2), 7, 1) ~ ' ' ~ d($a) };
    t "$n.atomic.md.oob",   { my $a := shifted(5, 6, 7); nqp::atomicload_i(mdref($a, 3)) };
    t "$n.atomic.md.2",     { my $a := shifted(5, 6, 7); nqp::atomicload_i(mdref($a, 0, 1)) };
    t "$n.atomic.md.0",     { my $a := shifted(5, 6, 7); nqp::atomicload_i(mdref($a)) };
    t "$n.atomic.uref",     { my $a := shifted(5, 6, 7); nqp::atomicload_i(nqp::atposref_u($a, 1)) };

    # Hot loops (specialized and compiled with spesh enabled).
    t "$n.hot.sum", {
        my $a := fresh(^50);
        my int $s = 0;
        my int $i = 0;
        while $i < 200000 {
            $a[$i % 50] = $i;
            $s = $s + $a[($i + 7) % 50] + $a.elems;
            $i = $i + 1;
        }
        $s ~ ' ' ~ dbig($a)
    };
    t "$n.hot.nqp", {
        my $a := fresh(^50);
        my int $s = 0;
        my int $i = 0;
        while $i < 200000 {
            nqp::bindpos_i($a, $i % 50, $i);
            $s = $s + nqp::atpos_i($a, -1 - ($i % 50)) + nqp::atpos_i($a, 50 + $i % 2) + nqp::elems($a);
            $i = $i + 1;
        }
        $s ~ ' ' ~ dbig($a)
    };
    t "$n.hot.pushpop", {
        my $a := fresh();
        my int $s = 0;
        my int $i = 0;
        while $i < 100000 {
            $a.push($i); $a.push($i + 1); $a.unshift($i + 2);
            $s = $s + $a.pop + $a.shift;
            $i = $i + 1;
        }
        $s ~ ' ' ~ dbig($a)
    };
}

# The atomicint array through the language's own atomic operators.
t 'atomicint.cas',        { my atomicint @a = 5, 6, 7; cas(@a[1], 6, 9) ~ ' ' ~ cas(@a[1], 6, 10) ~ ' ' ~ d(@a) };
t 'atomicint.fetch',      { my atomicint @a = 5, 6, 7; atomic-fetch(@a[2]) ~ ' ' ~ ⚛@a[0] };
t 'atomicint.assign',     { my atomicint @a = 5, 6, 7; atomic-assign(@a[0], 1); @a[1] ⚛= 2; d(@a) };
t 'atomicint.inc',        { my atomicint @a = 5, 6, 7; @a[0]⚛++; ++⚛@a[0]; @a[1]⚛--; @a[2] ⚛+= 10; @a[2] ⚛-= 1; d(@a) };
t 'atomicint.oob',        { my atomicint @a = 5, 6, 7; @a[5]⚛++; d(@a) };
t 'atomicint.cas.code',   { my atomicint @a = 5, 6, 7; cas(@a[0], -> $v { $v + 1 }) ~ ' ' ~ d(@a) };
t 'atomicint.threads',    {
    my atomicint @a = 0, 0;
    await (^4).map: { start { for ^5000 { @a[0]⚛++; @a[1] ⚛+= 2 } } };
    d(@a)
};

# ---------------------------------------------------------- native num arrays

for @num-types -> \T {
    my $n = T.^name;
    my sub fresh(*@v) { my $a := array[T].new; $a.push($_) for @v; $a }
    my sub shifted(*@v) { my $a := array[T].new(90e0, 91e0, 92e0); $a.push($_) for @v; $a.shift xx 3; $a }
    my @v = 0.5e0, 1.5e0, 2.5e0, 3.5e0, 4.5e0, 5.5e0;

    t "$n.type",            { my $a := fresh(); nqp::reprname($a) ~ ' ' ~ $a.^name ~ ' ' ~ nqp::objprimspec(T) ~ ' ' ~ nqp::objprimbits(T) };
    t "$n.empty",           { my $a := fresh(); $a.elems ~ ' ' ~ $a[0] ~ ' ' ~ $a[3] ~ ' ' ~ nqp::atpos_n($a, 9) };
    t "$n.empty.at-1",      { nqp::atpos_n(fresh(), -1) };
    t "$n.empty.pop",       { fresh().pop };
    t "$n.empty.shift",     { fresh().shift };
    t "$n.push",            { my $a := fresh(); $a.push($_ + 0.25e0) for ^20; d($a) };
    t "$n.pop",             { my $a := fresh(@v); $a.pop ~ ' ' ~ $a.pop ~ ' ' ~ d($a) };
    t "$n.shift",           { my $a := fresh(@v); $a.shift ~ ' ' ~ $a.shift ~ ' ' ~ d($a) };
    t "$n.unshift",         { my $a := fresh(@v); $a.unshift(9e0); $a.unshift(8e0, 7e0); $a.prepend(6e0, 5e0); d($a) };
    t "$n.unshift.many",    { my $a := fresh(); $a.unshift($_ + 0.5e0) for ^300; dbig($a) };
    t "$n.assign",          { my $a := fresh(@v); $a[2] = 9e0; $a[*-1] = 8e0; $a[8] = 7e0; d($a) };
    t "$n.nqp",             { my $a := shifted(@v); nqp::bindpos_n($a, -1, 9e0); nqp::atpos_n($a, 0) ~ ' ' ~ nqp::atpos_n($a, -1) ~ ' ' ~ nqp::atpos_n($a, 6) ~ ' ' ~ d($a) };
    t "$n.nqp.oob",         { my $a := shifted(@v); nqp::atpos_n($a, -7) };
    t "$n.nqp.bind.oob",    { my $a := shifted(@v); nqp::bindpos_n($a, -7, 1e0) };
    t "$n.nqp.wrongkind",   { my $a := shifted(@v); nqp::atpos_i($a, 0) };
    t "$n.nqp.wrongkind.u", { my $a := shifted(@v); my uint $u = nqp::atpos_u($a, 0); $u };
    t "$n.nqp.wrongkind.bind", { my $a := shifted(@v); nqp::bindpos_i($a, 9, 1); d($a) };
    t "$n.nqp.wrongkind.after", { my $a := shifted(@v); try nqp::bindpos_i($a, 9, 1); try nqp::push_i($a, 1); try nqp::pop_i($a); try nqp::unshift_s($a, 'x'); d($a) };
    t "$n.elems.set",       { my $a := fresh(@v); nqp::setelems($a, 8); my $r = d($a); nqp::setelems($a, 2); nqp::setelems($a, 4); $r ~ ' / ' ~ d($a) };
    t "$n.slice",           { my $a := shifted(@v); $a[1..3].join(' ') ~ ' / ' ~ d(nqp::slice($a, 1, -2)) };
    t "$n.clone",           { my $a := shifted(@v); my $c := $a.clone; $c.push(7e0); $a.shift; d($c) ~ ' / ' ~ d($a) };
    t "$n.splice",          { my $a := shifted(@v); my $r := $a.splice(1, 2, (7e0, 8e0, 9e0)); d($r) ~ ' / ' ~ d($a) };
    t "$n.splice.delete",   { my $a := shifted(@v); $a.splice(0, 4); d($a) };
    t "$n.splice.self",     { my $a := fresh(@v); nqp::splice($a, $a, 3, 0); d($a) };
    t "$n.splice.from.other", { my $a := fresh(@v); nqp::splice($a, array[T === num32 ?? num64 !! num32].new(0.1e0, 1e39), 1, 1); d($a) };
    t "$n.splice.from.int", { my $a := fresh(@v); nqp::splice($a, array[int64].new(4607182418800017408, 1), 1, 1); d($a) };
    t "$n.iterate",         { my $a := shifted(@v); $a.sum ~ ' ' ~ $a.map(* * 2).join(' ') ~ ' ' ~ $a.reverse.join(' ') ~ ' ' ~ $a.sort.join(' ') };
    t "$n.join",            { my $a := shifted(@v); $a.join(',') ~ ' ' ~ $a.gist ~ ' ' ~ $a.raku };
    t "$n.flatten",         { my $a := shifted(@v); (sub (*@x) { @x.join(',') })(|$a) };
    for 0e0, -0e0, 1e0, NaN, Inf, -Inf, 0.1e0, 1e0/3e0, 16777217e0, 3.4028234663852886e38, 3.4028235677973366e38,
        1e39, -1e39, 1.401298464324817e-45, 1e-46, -1e-46, 1.7976931348623157e308, 5e-324 -> $v {
        t "$n.value.$v", {
            my $a := fresh();
            $a[0] = $v; $a.push($v); $a.unshift($v); $a.splice(1, 0, ($v,));
            my $r = $a.list.map(*.raku).join(' ');
            my $b := array[T].new($v, $v);
            $r ~ ' pop=' ~ $b.pop.raku ~ ' shift=' ~ $b.shift.raku ~ ' atpos=' ~ nqp::atpos_n($a, 0).raku
                ~ ' sign=' ~ ($a[0] === -0e0 ?? 'negzero' !! $a[0].sign)
        };
    }
    t "$n.ref.read",        { my $a := shifted(@v); my $r := nqp::atposref_n($a, 1); $r ~ ' ' ~ $r.^name };
    t "$n.ref.write",       { my $a := shifted(@v); my $r := nqp::atposref_n($a, 1); $r = 9e0; $r += 1e0; d($a) };
    t "$n.ref.neg",         { my $a := shifted(@v); my $r := nqp::atposref_n($a, -1); $r = $r + 1e0; d($a) };
    t "$n.ref.past",        { my $a := shifted(@v); my $r := nqp::atposref_n($a, 8); my $x = $r + 0e0; $r = 3e0; $x ~ ' ' ~ d($a) };
    t "$n.ref.oob.read",    { my $a := shifted(@v); my $r := nqp::atposref_n($a, -7); $r + 0e0 };
    t "$n.ref.oob.write",   { my $a := shifted(@v); my $r := nqp::atposref_n($a, -7); $r = 1e0; d($a) };
    t "$n.ref.wrong.i",     { my $a := shifted(@v); my $r := nqp::atposref_i($a, 0); $r + 0 };
    t "$n.ref.wrong.i.write", { my $a := shifted(@v); my $r := nqp::atposref_i($a, 0); $r = 1; d($a) };
    t "$n.ref.postfix",     { my $a := shifted(@v); $a[0]++; $a[1] += 10e0; $a[2] *= 2e0; d($a) };
    t "$n.mdref",           { my $a := shifted(@v); my $r := nqp::multidimref_n($a, nqp::list_i(1)); $r = $r + 1e0; d($a) };
    t "$n.mdref.2",         { my $a := shifted(@v); my $r := nqp::multidimref_n($a, nqp::list_i(1, 1)); $r + 0e0 };
    t "$n.atomic",          { my $a := shifted(@v); nqp::atomicload_i(nqp::atposref_i($a, 0)) };
    t "$n.hot.sum", {
        my $a := fresh((^50).map(*.Num));
        my num $s = 0e0;
        my int $i = 0;
        while $i < 200000 {
            $a[$i % 50] = $i + 0.5e0;
            $s = $s + $a[($i + 7) % 50] + nqp::atpos_n($a, -1 - ($i % 50)) + nqp::atpos_n($a, 51);
            $i = $i + 1;
        }
        $s ~ ' ' ~ dbig($a)
    };
}

# ---------------------------------------------------------- native str arrays

{
    my $n = 'str';
    my sub fresh(*@v) { my $a := array[str].new; $a.push($_) for @v; $a }
    my sub shifted(*@v) { my $a := array[str].new('x', 'y', 'z'); $a.push($_) for @v; $a.shift xx 3; $a }
    my @v = <a b c d e f>;
    t "$n.type",            { my $a := fresh(); nqp::reprname($a) ~ ' ' ~ $a.^name ~ ' ' ~ nqp::objprimspec(str) };
    t "$n.empty",           { my $a := fresh(); $a.elems ~ ' ' ~ nqp::isnull_s(nqp::atpos_s($a, 0)) ~ ' ' ~ nqp::isnull_s(nqp::atpos_s($a, 3)) };
    t "$n.empty.pop",       { fresh().pop };
    t "$n.empty.shift",     { fresh().shift };
    t "$n.push",            { my $a := fresh(); $a.push("s$_") for ^20; d($a) };
    t "$n.poppers",         { my $a := shifted(@v); $a.pop ~ $a.shift ~ ' ' ~ d($a) };
    t "$n.unshift",         { my $a := shifted(@v); $a.unshift('u'); $a.prepend('p', 'q'); $a.append('r'); d($a) };
    t "$n.unshift.many",    { my $a := fresh(); $a.unshift("s$_") for ^300; dbig($a) };
    t "$n.assign",          { my $a := shifted(@v); $a[1] = 'B'; $a[*-1] = 'F'; d($a) };
    t "$n.assign.gap",      { my $a := shifted(@v); $a[8] = 'I'; $a.elems ~ ' ' ~ nqp::isnull_s(nqp::atpos_s($a, 7)) ~ ' ' ~ nqp::atpos_s($a, 8) };
    t "$n.nqp.oob",         { nqp::atpos_s(shifted(@v), -7) };
    t "$n.nqp.wrongkind",   { nqp::atpos_i(shifted(@v), 0) };
    t "$n.nqp.wrongkind.o", { nqp::isnull(nqp::atpos(shifted(@v), 0)) };
    t "$n.nqp.wrongkind.push", { my $a := shifted(@v); nqp::push_i($a, 1); d($a) };
    t "$n.nqp.wrongkind.after", { my $a := shifted(@v); try nqp::push_i($a, 1); try nqp::unshift_i($a, 1); $a.elems ~ ' ' ~ nqp::isnull_s(nqp::atpos_s($a, 0)) ~ ' ' ~ nqp::atpos_s($a, 1) ~ ' ' ~ nqp::isnull_s(nqp::atpos_s($a, -1)) };
    t "$n.slice",           { my $a := shifted(@v); $a[1..3].join(' ') ~ ' / ' ~ d(nqp::slice($a, 1, -2)) };
    t "$n.clone",           { my $a := shifted(@v); my $c := $a.clone; $c.push('g'); $a.shift; d($c) ~ ' / ' ~ d($a) };
    t "$n.splice",          { my $a := shifted(@v); my $r := $a.splice(1, 2, <X Y Z>); d($r) ~ ' / ' ~ d($a) };
    t "$n.splice.delete",   { my $a := shifted(@v); $a.splice(0, 4); d($a) };
    t "$n.splice.self",     { my $a := fresh(@v); nqp::splice($a, $a, 3, 0); d($a) };
    t "$n.splice.self.1",   { my $a := fresh(@v); nqp::splice($a, $a, 1, 0); d($a) };
    t "$n.iterate",         { my $a := shifted(@v); $a.map(*.uc).join ~ ' ' ~ $a.reverse.join ~ ' ' ~ $a.sort.join ~ ' ' ~ $a.join(',') ~ ' ' ~ $a.gist ~ ' ' ~ $a.raku };
    t "$n.join",            { my $a := shifted(@v); nqp::join('-', $a) };
    t "$n.flatten",         { my $a := shifted(@v); (sub (*@x) { @x.join(',') })(|$a) };
    t "$n.ref.read",        { my $a := shifted(@v); my $r := nqp::atposref_s($a, 1); $r ~ ' ' ~ $r.^name };
    t "$n.ref.write",       { my $a := shifted(@v); my $r := nqp::atposref_s($a, 1); $r = 'B'; $r ~= '!'; d($a) };
    t "$n.ref.neg",         { my $a := shifted(@v); my $r := nqp::atposref_s($a, -1); $r = $r ~ '+'; d($a) };
    t "$n.ref.past",        { my $a := shifted(@v); my $r := nqp::atposref_s($a, 6); $r = 'G'; d($a) };
    t "$n.ref.oob.read",    { my $a := shifted(@v); my $r := nqp::atposref_s($a, -7); $r ~ '' };
    t "$n.ref.oob.write",   { my $a := shifted(@v); my $r := nqp::atposref_s($a, -7); $r = 'x'; d($a) };
    t "$n.ref.wrong.i",     { my $a := shifted(@v); my $r := nqp::atposref_i($a, 0); $r + 0 };
    t "$n.ref.wrong.n",     { my $a := shifted(@v); my $r := nqp::atposref_n($a, 0); $r + 0e0 };
    t "$n.mdref",           { my $a := shifted(@v); my $r := nqp::multidimref_s($a, nqp::list_i(1)); $r = $r ~ '!'; d($a) };
    t "$n.mdref.2",         { my $a := shifted(@v); my $r := nqp::multidimref_s($a, nqp::list_i(1, 1)); $r ~ '' };
    t "$n.atomic",          { my $a := shifted(@v); nqp::atomicload_i(nqp::atposref_i($a, 0)) };
    t "$n.gc",              { my $a := fresh(); for ^20000 { $a.push("s" ~ $_); $a.shift if $_ %% 3 }; nqp::force_gc(); for ^20000 { $a.unshift("u" ~ $_) }; nqp::force_gc(); dbig($a) };
    t "$n.hot",             {
        my $a := fresh((^50).map(*.Str));
        my int $s = 0;
        my int $i = 0;
        while $i < 100000 {
            $a[$i % 50] = nqp::tostr_I($i % 1000);
            $s = $s + nqp::chars($a[($i + 7) % 50]);
            $i = $i + 1;
        }
        $s ~ ' ' ~ dbig($a)
    };
}

# ---------------------------------------------------------------------- bufs

for buf8, buf16, buf32, buf64, blob8, blob16, blob32, blob64 -> \T {
    my $n = T.^name;
    my $mutable = $n.starts-with('buf');
    my sub fresh(*@v) { T.new(@v) }
    t "$n.type",            { my $b := fresh(1, 2); nqp::reprname($b) ~ ' ' ~ $b.^name ~ ' ' ~ $b.elems ~ ' ' ~ $b.bytes };
    t "$n.empty",           { my $b := fresh(); $b.elems ~ ' ' ~ $b.Bool ~ ' ' ~ $b.gist ~ ' ' ~ nqp::atpos_i($b, 0) };
    t "$n.new.values",      { d(fresh(0, 1, 255, 256, 65535, 65536, 4294967295, 4294967296, -1, -129, 9223372036854775807)) };
    t "$n.new.big",         { d(fresh(18446744073709551615)) };
    t "$n.at",              { my $b := fresh(5, 6, 7); $b[0] ~ ' ' ~ $b[2] ~ ' ' ~ $b[*-1] ~ ' ' ~ nqp::atpos_i($b, 3) ~ ' ' ~ nqp::atpos_i($b, -3) };
    t "$n.at.oob",          { nqp::atpos_i(fresh(5, 6, 7), -4) };
    t "$n.at.u",            { my $b := fresh(5, 6, 7); my uint $u = nqp::atpos_u($b, -1); $u };
    t "$n.assign",          { my $b := fresh(5, 6, 7); $b[1] = 300; $b[5] = 9; d($b) };
    t "$n.push",            { my $b := fresh(5, 6, 7); $b.push(8); $b.push(9, 10); $b.append(11, 12); $b.append(fresh(13)); d($b) };
    t "$n.unshift",         { my $b := fresh(5, 6, 7); $b.unshift(4); $b.prepend(2, 3); d($b) };
    t "$n.pop",             { my $b := fresh(5, 6, 7); $b.pop ~ ' ' ~ $b.shift ~ ' ' ~ d($b) };
    t "$n.pop.empty",       { nqp::pop_i(fresh()) };
    t "$n.shift.empty",     { nqp::shift_i(fresh()) };
    t "$n.splice",          { my $b := fresh(1, 2, 3, 4, 5, 6); my $r := $b.splice(1, 2, (7, 8, 9)); d($r) ~ ' / ' ~ d($b) };
    t "$n.splice.blob",     { my $b := fresh(1, 2, 3, 4, 5, 6); $b.splice(4, 5, fresh(7, 8)); d($b) };
    t "$n.splice.self",     { my $b := fresh(1, 2, 3, 4, 5, 6); nqp::splice($b, $b, 3, 0); d($b) };
    t "$n.subbuf",          { my $b := fresh(1, 2, 3, 4, 5, 6); d($b.subbuf(1, 3)) ~ ' / ' ~ d($b.subbuf(4)) ~ ' / ' ~ d($b.subbuf(*-2)) ~ ' / ' ~ d($b.subbuf(6)) ~ ' / ' ~ d($b.subbuf(2, 100)) };
    t "$n.subbuf.oob",      { d(fresh(1, 2, 3).subbuf(4)) };
    t "$n.subbuf-rw",       { my $b := fresh(1, 2, 3, 4, 5, 6); $b.subbuf-rw(1, 2) = fresh(9, 9, 9); d($b) };
    t "$n.subbuf-rw.shrink", { my $b := fresh(1, 2, 3, 4, 5, 6); $b.subbuf-rw(2) = fresh(8); d($b) };
    t "$n.concat",          { my $b := fresh(1, 2); my $c := $b ~ fresh(3, 4) ~ fresh(); d($c) ~ ' ' ~ $c.^name ~ ' / ' ~ d($b) };
    t "$n.concat.self",     { my $b := fresh(1, 2, 3); d($b ~ $b) };
    t "$n.repeat",          { d(fresh(1, 2) x 3) };
    t "$n.reallocate",      { my $b := fresh(1, 2, 3); $b.reallocate(6); my $r = d($b); $b.reallocate(2); $b.reallocate(4); $r ~ ' / ' ~ d($b) };
    t "$n.allocate",        { d(T.allocate(5)) ~ ' / ' ~ d(T.allocate(5, 7)) ~ ' / ' ~ d(T.allocate(7, (1, 2, 3))) ~ ' / ' ~ d(T.allocate(0)) };
    t "$n.allocate.big",    { my $b := T.allocate(20000, 3); $b.elems ~ ' ' ~ $b[19999] ~ ' ' ~ nqp::atpos_i($b, 20000) ~ ' ' ~ $b.subbuf(19990).elems };
    t "$n.compare",         { my $b := fresh(1, 2, 3); ($b eqv fresh(1, 2, 3)) ~ ' ' ~ ($b eq fresh(1, 2, 3)) ~ ' ' ~ ($b cmp fresh(1, 2, 4)) ~ ' ' ~ ($b cmp fresh(1, 2)) ~ ' ' ~ ($b == fresh(4, 5, 6)) };
    t "$n.list",            { my $b := fresh(1, 2, 3); $b.list.join(',') ~ ' ' ~ $b.reverse.list.join(',') ~ ' ' ~ $b.gist ~ ' ' ~ $b.raku ~ ' ' ~ $b.Int ~ ' ' ~ $b.Numeric };
    t "$n.bitops",          { d(fresh(1, 2, 3) ~| fresh(4, 8)) ~ ' ' ~ d(fresh(7, 7, 7) ~& fresh(5, 2)) ~ ' ' ~ d(fresh(1, 2, 3) ~^ fresh(1, 1)) };
    t "$n.clone",           { my $b := fresh(1, 2, 3); my $c := $b.clone; $c.push(4) if $mutable; d($c) ~ ' / ' ~ d($b) };
    t "$n.nqp.slice",       { my $b := fresh(1, 2, 3, 4, 5); d(nqp::slice($b, 1, -2)) };
    t "$n.nqp.setelems",    { my $b := fresh(1, 2, 3); nqp::setelems($b, 5); nqp::bindpos_i($b, -1, 9); d($b) };
    t "$n.nqp.readint",     { my $b := fresh(0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89); (0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14).map({ nqp::readint($b, 0, $_) ~ '/' ~ nqp::readuint($b, 1, $_) }).join(' ') };
    t "$n.nqp.writeint",    { my $b := fresh(1, 2, 3); (0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14).map({ my $c := $b.clone; nqp::writeint($c, 1, 0x0102030405060788, $_); d($c) }).join(' ') };
    t "$n.nqp.readint.oob", { nqp::readint(fresh(1, 2, 3), 3, 0) };
    t "$n.nqp.writeint.neg", { my $b := fresh(1, 2, 3); nqp::writeint($b, -1, 1, 0); d($b) };
    t "$n.hot",             {
        my $b := T.allocate(64);
        my int $s = 0;
        my int $i = 0;
        while $i < 200000 {
            nqp::bindpos_i($b, $i % 64, $i);
            $s = $s + nqp::atpos_i($b, ($i + 9) % 64) + $b[$i % 64];
            $i = $i + 1;
        }
        $s ~ ' ' ~ dbig($b)
    };
}

# The read-* and write-* methods of a buf8 and a blob8: every size, both
# endiannesses and the native one, in range and out of range.
{
    my @bytes = 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x00, 0x00, 0x80, 0x3f, 0x18, 0x2d, 0x44, 0x54, 0xfb, 0x21, 0x09, 0x40;
    for buf8, blob8 -> \T {
        my $n = T.^name;
        my $b := T.new(@bytes);
        for NativeEndian, LittleEndian, BigEndian -> $e {
            for <read-uint8 read-int8 read-uint16 read-int16 read-uint32 read-int32 read-uint64 read-int64 read-uint128 read-int128 read-num32 read-num64> -> $m {
                t "$n.$m.$e",          { $b."$m"(0, $e) ~ ' ' ~ $b."$m"(3, $e) ~ ' ' ~ $b."$m"(8, $e) };
                t "$n.$m.$e.end",      { $b."$m"(19, $e) };
                t "$n.$m.$e.past",     { $b."$m"(20, $e) };
                t "$n.$m.$e.neg",      { $b."$m"(-1, $e) };
            }
            t "$n.read-ubits.$e",      { $b.read-ubits(0, 12) ~ ' ' ~ $b.read-ubits(5, 21) ~ ' ' ~ $b.read-bits(3, 70) ~ ' ' ~ $b.read-ubits(150, 10) };
            t "$n.read-ubits.$e.past", { $b.read-ubits(155, 10) };
        }
    }
    for NativeEndian, LittleEndian, BigEndian -> $e {
        for <write-uint8 write-int8 write-uint16 write-int16 write-uint32 write-int32 write-uint64 write-int64 write-uint128 write-int128> -> $m {
            t "buf8.$m.$e",            { my $b := buf8.new(1, 2, 3); $b."$m"(1, 0x0102030405060788, $e); d($b) };
            t "buf8.$m.$e.neg",        { my $b := buf8.new(1, 2, 3); $b."$m"(0, -2, $e); d($b) };
            t "buf8.$m.$e.grow",       { my $b := buf8.new(1, 2, 3); $b."$m"(6, 0x1122334455667788, $e); d($b) };
            t "buf8.$m.$e.empty",      { my $b := buf8.new; $b."$m"(0, 0x1122334455667788, $e); d($b) };
            t "buf8.$m.$e.negoffset",  { my $b := buf8.new(1, 2, 3); $b."$m"(-1, 1, $e); d($b) };
            t "buf8.$m.$e.type",       { d(buf8."$m"(2, 0x0102030405060788, $e)) };
            t "blob8.$m.$e",           { my $b := blob8.new(1, 2, 3); $b."$m"(1, 5, $e); d($b) };
        }
        for <write-num32 write-num64> -> $m {
            t "buf8.$m.$e",            { my $b := buf8.new(1, 2, 3); $b."$m"(1, 0.1e0, $e); d($b) };
            t "buf8.$m.$e.special",    { (NaN, Inf, -0e0, 1e39).map({ my $b := buf8.new; $b."$m"(0, $_, $e); d($b) }).join(' ') };
            t "buf8.$m.$e.grow",       { my $b := buf8.new(1, 2, 3); $b."$m"(5, -1.5e0, $e); d($b) };
        }
        t "buf8.write-ubits.$e",       { my $b := buf8.new(1, 2, 3); $b.write-ubits(4, 12, 0xabc); $b.write-bits(30, 9, -3); d($b) };
    }
    t 'buf8.nqp.readnum',  { my $b := buf8.new(@bytes); (8, 9, 10, 12, 13, 14).map({ nqp::readnum($b, $_ < 12 ?? 8 !! 12, $_) }).join(' ') };
    t 'buf8.nqp.writenum', { (8, 9, 10, 12, 13, 14).map({ my $b := buf8.new(1, 2); nqp::writenum($b, 1, 0.1e0, $_); d($b) }).join(' ') };
    t 'buf8.nqp.readnum.oob', { nqp::readnum(buf8.new(1, 2, 3), 0, 12) };
    t 'buf8.nqp.shifted',  { my $b := buf8.new(9, 9, 1, 2, 3); $b.shift; $b.shift; nqp::readint($b, 2, 0) ~ ' ' ~ nqp::readint($b, 3, 0) ~ ' ' ~ nqp::readint($b, 4, 0) };
    t 'buf8.nqp.shifted.past', { my $b := buf8.new(9, 9, 1, 2, 3); $b.shift; $b.shift; nqp::readint($b, 5, 0) };
    t 'buf8.nqp.shifted.write', { my $b := buf8.new(9, 9, 1, 2, 3); $b.shift; $b.shift; nqp::writeint($b, 2, 0x0102030405060708, 13); d($b) };
    t 'buf64.nqp.writeint', { my $b := buf64.new(1, 2, 3); nqp::writeint($b, 2, 0x0102, 4); my $r = d($b); nqp::writeint($b, 3, 5, 0); $r ~ ' / ' ~ d($b) };
    t 'buf64.nqp.readint',  { my $b := buf64.new(0x0102030405060708, 2, 3); nqp::readint($b, 0, 0) ~ ' ' ~ nqp::readint($b, 0, 4) ~ ' ' ~ nqp::readint($b, 2, 12) ~ ' ' ~ nqp::readint($b, 0, 14) };
    t 'buf64.nqp.readint.oob', { nqp::readint(buf64.new(1, 2, 3), 3, 0) };
    t 'num64.nqp.readint',  { my $a := array[num64].new(1.5e0, -0e0); nqp::readint($a, 0, 12) ~ ' ' ~ nqp::readint($a, 1, 12) };
    t 'num32.nqp.writeint', { my $a := array[num32].new(1.5e0, 2.5e0); nqp::writeint($a, 1, 0x3f800000, 8); d($a) };
    t 'str.nqp.readint',    { nqp::readint(array[str].new('a'), 0, 0) };
    t 'str.nqp.writeint',   { my $a := array[str].new('a'); nqp::writeint($a, 0, 1, 0); d($a) };
    t 'list.nqp.readint',   { nqp::readint(nqp::list(1), 0, 0) };
    t 'encode',             { my $b := 'héllo wörld ✓'.encode('utf-8'); d($b) ~ ' ' ~ $b.^name ~ ' ' ~ $b.decode };
    t 'encode.utf16',       { my $b := 'héllo ✓ 𝄞'.encode('utf-16'); d($b) ~ ' ' ~ $b.^name ~ ' ' ~ $b.decode('utf-16') };
    t 'encode.utf32',       { my $b := 'hé𝄞'.encode('utf-32'); d($b) ~ ' ' ~ $b.^name };
    t 'encode.latin1',      { my $b := 'héllo'.encode('latin-1'); d($b) ~ ' ' ~ $b.decode('latin-1') };
    t 'decode.shifted',     { my $b := buf8.new(0, 0, |'shifted'.encode.list); $b.shift; $b.shift; $b.push(33); $b.decode };
    t 'decode.invalid',     { buf8.new(0xff, 0xfe, 0x41).decode('utf-8') };
    t 'pack',               { my $b := buf8.new(1, 2, 3, 4); $b.unshift(0) for ^10; $b.pop for ^3; d($b) ~ ' ' ~ $b.decode('latin-1').ords.join(',') };
    t 'buf8.grow',          { my $b := buf8.new; $b.push($_ % 251) for ^30000; $b.shift for ^1000; $b.unshift($_ % 7) for ^9000; dbig($b) };
    t 'buf8.join',          { nqp::join(',', buf8.new(1, 2)) };
}

# ------------------------------------------------- the VMArray inside an Array

{
    my sub reified(@a) { nqp::getattr(@a, List, '$!reified') }
    my sub od(\b) {
        my @p;
        my int $e = nqp::elems(b);
        my int $i = 0;
        while $i < $e {
            my \v = nqp::atpos(b, $i);
            @p.push: nqp::isnull(v) ?? '<null>' !! nqp::iscont(v) ?? nqp::decont(v).gist !! v.gist;
            $i = $i + 1;
        }
        "elems=$e [" ~ @p.join(' ') ~ ']'
    }
    t 'array.reified.type',   { my @a = 1, 2, 3; my \b = reified(@a); nqp::reprname(b) ~ ' ' ~ b.^name ~ ' ' ~ nqp::elems(b) ~ ' ' ~ nqp::objprimspec(b.WHAT) };
    t 'array.reified.dump',   { my @a = 1, 2, 3; @a.push(4); @a.shift; @a.unshift(0); od(reified(@a)) };
    t 'array.reified.gap',    { my @a = 1, 2, 3; @a[6] = 7; od(reified(@a)) ~ ' ' ~ @a.gist };
    t 'array.reified.at',     { my @a = 1, 2, 3; my \b = reified(@a); nqp::atpos(b, -1) ~ ' ' ~ nqp::isnull(nqp::atpos(b, 3)) ~ ' ' ~ nqp::existspos(b, 2) ~ ' ' ~ nqp::existspos(b, 3) ~ ' ' ~ nqp::existspos(b, -1) ~ ' ' ~ nqp::existspos(b, -4) };
    t 'array.reified.oob',    { my @a = 1, 2, 3; nqp::atpos(reified(@a), -4) };
    t 'array.reified.wrong',  { my @a = 1, 2, 3; nqp::atpos_i(reified(@a), 0) };
    t 'array.reified.wrong.push', { my @a = 1, 2, 3; nqp::push_i(reified(@a), 0); @a.elems };
    t 'array.reified.nqp',    { my @a = 1, 2, 3; my \b = reified(@a); nqp::push(b, 4); nqp::unshift(b, 0); nqp::bindpos(b, 2, 'two'); nqp::pop(b) ~ nqp::shift(b) ~ ' ' ~ od(b) };
    t 'array.reified.splice', { my @a = 1, 2, 3, 4, 5; my \b = reified(@a); nqp::splice(b, nqp::list(7, 8), 1, 2); nqp::splice(b, b, 2, 0); od(b) };
    t 'array.reified.slice',  { my @a = 1, 2, 3, 4, 5; od(nqp::slice(reified(@a), 1, -2)) };
    t 'array.reified.clone',  { my @a = 1, 2, 3; my \c = nqp::clone(reified(@a)); nqp::push(c, 9); od(c) ~ ' / ' ~ od(reified(@a)) };
    t 'array.reified.setelems', { my @a = 1, 2, 3; my \b = reified(@a); nqp::setelems(b, 5); my $r = od(b); nqp::setelems(b, 1); nqp::setelems(b, 2); $r ~ ' / ' ~ od(b) };
    t 'array.reified.join',   { my @a = 'a', 'b'; nqp::join(',', nqp::list('x', 'y')) };
    t 'array.reified.atomic', { my @a = 1, 2, 3; nqp::atomicload_i(nqp::atposref_i(reified(@a), 0)) };
    t 'array.reified.ref',    { my @a = 1, 2, 3; my $r := nqp::atposref_i(reified(@a), 0); $r + 0 };
    t 'array.reified.nd',     { my @a = 1, 2, 3; my \b = reified(@a); nqp::atposnd(b, nqp::list_i(1)) ~ ' ' ~ nqp::numdimensions(b) ~ ' ' ~ nqp::atpos_i(nqp::dimensions(b), 0) };
    t 'array.reified.nd.2',   { my @a = 1, 2, 3; nqp::atpos2d(reified(@a), 0, 0) };
    t 'array.reified.setdimensions', { my @a = 1, 2, 3; nqp::setdimensions(reified(@a), nqp::list_i(1, 1)) };
    t 'array.reified.readint', { my @a = 1, 2, 3; nqp::readint(reified(@a), 0, 0) };

    t 'array.push',           { my @a; @a.push($_) for ^20; @a.join(' ') };
    t 'array.poppers',        { my @a = ^10; @a.pop ~ @a.shift ~ ' ' ~ @a.join(' ') };
    t 'array.empty.pop',      { my @a; my $x = @a.pop; $x.defined ?? ~$x !! $x.exception.message };
    t 'array.empty.shift',    { my @a; my $x = @a.shift; $x.defined ?? ~$x !! $x.exception.message };
    t 'array.unshift',        { my @a = ^5; @a.unshift(9); @a.unshift(8, 7); @a.prepend(6, 5); @a.join(' ') };
    t 'array.unshift.many',   { my @a; @a.unshift($_) for ^20000; @a.elems ~ ' ' ~ @a[0, 1, 19999].join(' ') ~ ' ' ~ @a.sum };
    t 'array.queue',          { my @a; my $s = 0; for ^20000 { @a.push($_); @a.push($_); $s += @a.shift }; $s ~ ' ' ~ @a.elems ~ ' ' ~ @a[0] ~ ' ' ~ @a[*-1] };
    t 'array.stack',          { my @a; my $s = 0; for ^20000 { @a.unshift($_); @a.unshift($_); $s += @a.pop }; $s ~ ' ' ~ @a.elems ~ ' ' ~ @a[0] ~ ' ' ~ @a[*-1] };
    for (
        'insert.front',   (0, 0, (7, 8)),      'insert.middle', (3, 0, (7, 8)),
        'insert.end',     (6, 0, (7, 8)),      'delete.front',  (0, 2, ()),
        'delete.middle',  (2, 2, ()),          'delete.tail',   (4, 2, ()),
        'delete.all',     (0, 6, ()),          'replace.same',   (1, 2, (7, 8)),
        'replace.shorter', (1, 4, (7, 8)),     'replace.longer', (1, 1, (7, 8, 9)),
        'replace.front', (0, 3, (7, 8, 9, 10, 11)),
    ) -> $name, ($off, $cnt, $new) {
        t "array.splice.$name",         { my @a = ^6; my @r = @a.splice($off, $cnt, @$new); @r.join(' ') ~ ' / ' ~ @a.join(' ') };
        t "array.splice.$name.shifted", { my @a = 90, 91, 92, |^6; @a.shift xx 3; my @r = @a.splice($off, $cnt, @$new); @r.join(' ') ~ ' / ' ~ @a.join(' ') };
    }
    t 'array.splice.self',    { my @a = ^6; @a.splice(2, 1, @a); @a.join(' ') };
    t 'array.splice.past',    { my @a = ^6; @a.splice(8, 0, 1); @a.join(' ') };
    t 'array.splice.big',     { my @a = ^20000; @a.splice(100, 15000); @a.splice(50, 0, ^9000); @a.elems ~ ' ' ~ @a.sum ~ ' ' ~ @a[49, 50, 9050, *-1].join(' ') };
    t 'array.grow',           { my @a; @a[$_] = $_ for 0, 7, 8, 100, 8191, 8192, 9000, 20000; @a.elems ~ ' ' ~ @a.grep(*.defined).join(' ') };
    t 'array.gc',             {
        my @a;
        for ^50000 { @a.push([$_, "s$_"]); @a.shift if $_ %% 2 }
        nqp::force_gc();
        @a.unshift(["u$_"]) for ^5000;
        nqp::force_gc();
        @a.elems ~ ' ' ~ @a[0][0] ~ ' ' ~ @a[5000][0] ~ ' ' ~ @a[*-1][1] ~ ' ' ~ @a.map(*.elems).sum
    };
    t 'array.gc.old',         {
        my @a = ^1000;
        nqp::force_gc(); nqp::force_gc();
        @a[$_] = "young$_" for ^1000;
        @a.splice(500, 0, (^100).map({ "s$_" }));
        nqp::force_gc();
        @a.elems ~ ' ' ~ @a[0, 499, 500, 599, 600, 1099].join(' ')
    };
    t 'iterationbuffer',      { my $b := IterationBuffer.new; $b.push($_) for ^10; $b.unshift(-1); $b.elems ~ ' ' ~ $b.List.join(' ') ~ ' ' ~ nqp::reprname($b) };
    t 'list.slurpy',          { (sub (*@x) { @x.elems ~ ':' ~ @x.join(',') })(|(^300)) };
    t 'list.flatten.native',  { my int @a = ^5; (sub (int $a, int $b, int $c, int $d, int $e) { $a + $b + $c + $d + $e })(|@a) };
    t 'hash.keys.sorted',     { my %h = (^50).map({ "k$_" => $_ }); %h.keys.sort.elems ~ ' ' ~ %h.values.sum };
    t 'str.split.join',       { ('a,b,c,d' x 1000).split(',').elems ~ ' ' ~ (^1000).join('').chars ~ ' ' ~ 'a b c'.words.reverse.join(' ') };
}

say 'done: 1';
