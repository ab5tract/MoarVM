# The VMArray differential program, nqp half (spec
# traces/llm/specs/2026-11-16-zig-vmarray-repr-design.md, section 7 item 2).
#
# Drives every operation of src/6model/reprs/VMArray.c over every slot kind
# that has storage (OBJ, STR, I64, I32, I16, I8, U64, U32, U16, U8, N64, N32)
# and over the six kinds that have none (U4, U2, U1, I4, I2, I1), with fixed
# inputs. Every output line is
#     <case name>: <result>
# and a caught exception prints
#     <case name>: DIED <message>
# Nothing in the output varies from run to run: no addresses, no object ids,
# no hash iteration, no timings. tools/bench/repr/diff.sh runs it on two
# builds and compares the output byte for byte; the record of what the C array
# prints is traces/llm/bench/va-differential.md.
#
# Run: <prefix>/bin/nqp-m tools/bench/repr/vmarray-diff.nqp
#
# Deliberately absent, because the C array crashes or reads freed or foreign
# memory there (listed with the reasons in va-differential.md): setelems of
# 2**64 - 4096 or more on an array whose storage is 8,192 slots or larger;
# a splice from a non-empty object that is not a VMArray; a cross-kind splice
# between a reference kind and a numeric kind; growing an OBJ or STR array
# back over a slot a mismatched pop left behind, or splicing one from itself
# at offset 0 while its start is above zero (both read pointers the collector
# no longer tracks); a read_buf that the bounds check lets through but that
# lies beyond the storage; a splice that would copy elements into an array of
# a kind without storage (slot_type_to_kind aborts).

sub t($name, &code) {
    my $r;
    try { $r := code(); CATCH { $r := 'DIED ' ~ nqp::getmessage($!) } }
    say("$name: $r");
}

# ---------------------------------------------------------------- the kinds

sub arrtype($elem) {
    my $t := nqp::newtype(nqp::null(), 'VMArray');
    nqp::composetype($t, nqp::hash('array', nqp::hash('type', $elem)));
    $t
}
sub inttype(int $bits, int $unsigned) {
    my $t := nqp::newtype(nqp::null(), 'P6int');
    my $h := nqp::hash('bits', $bits);
    if $unsigned { $h<unsigned> := 1 }
    nqp::composetype($t, nqp::hash('integer', $h));
    $t
}
sub numtype(int $bits) {
    my $t := nqp::newtype(nqp::null(), 'P6num');
    nqp::composetype($t, nqp::hash('float', nqp::hash('bits', $bits)));
    $t
}

# A kind: name, register class (o s i u n), array type, element size in bytes
# and the size budget of set_size_internal for that element size.
my @kinds;
sub kind($name, $cls, $type, int $esize) {
    my $limit := $esize == 8 ?? 1152921504606846976      # 2**60
              !! $esize == 4 ?? 2305843009213693952      # 2**61
              !! $esize == 2 ?? 4611686018427387904      # 2**62
              !!                nqp::bitshiftl_i(1, 63); # 2**63, as bits
    nqp::push(@kinds, nqp::hash('name', $name, 'cls', $cls, 'type', $type,
        'esize', $esize, 'limit', $limit));
}
kind('obj', 'o', nqp::what(nqp::list()),   8);
kind('str', 's', nqp::what(nqp::list_s()), 8);
kind('i64', 'i', nqp::what(nqp::list_i()), 8);
kind('i32', 'i', arrtype(inttype(32, 0)),  4);
kind('i16', 'i', arrtype(inttype(16, 0)),  2);
kind('i8',  'i', arrtype(inttype(8, 0)),   1);
kind('u64', 'u', arrtype(inttype(64, 1)),  8);
kind('u32', 'u', arrtype(inttype(32, 1)),  4);
kind('u16', 'u', arrtype(inttype(16, 1)),  2);
kind('u8',  'u', arrtype(inttype(8, 1)),   1);
kind('n64', 'n', nqp::what(nqp::list_n()), 8);
kind('n32', 'n', arrtype(numtype(32)),     4);

sub kind_named($name) {
    for @kinds { return $_ if $_<name> eq $name }
    nqp::die("no kind $name");
}

# ------------------------------------------- natural operations per class

sub ostr($o) { nqp::isnull($o) ?? '<null>' !! ~$o }
sub sstr(str $s) { nqp::isnull_s($s) ?? '<null>' !! $s }

sub ival(int $j) { $j * 3 + 1 }
sub nval(int $j) { nqp::add_n($j, 0.25e0) }

sub mk($k) { nqp::create($k<type>) }

# The element at $i, read with the register kind natural to the class.
sub g($k, $a, int $i) {
    my $c := $k<cls>;
    if    $c eq 'i' { ~nqp::atpos_i($a, $i) }
    elsif $c eq 'u' { my uint $u := nqp::atpos_u($a, $i); my int $s := $u; ~$s }
    elsif $c eq 'n' { ~nqp::atpos_n($a, $i) }
    elsif $c eq 's' { my str $s := nqp::atpos_s($a, $i); nqp::isnull_s($s) ?? '<null>' !! $s }
    else            { my $o := nqp::atpos($a, $i); nqp::isnull($o) ?? '<null>' !! ~$o }
}
sub put($k, $a, int $i, int $j) {
    my $c := $k<cls>;
    if    $c eq 'i' { nqp::bindpos_i($a, $i, ival($j)) }
    elsif $c eq 'u' { my uint $u := ival($j); nqp::bindpos_u($a, $i, $u) }
    elsif $c eq 'n' { nqp::bindpos_n($a, $i, nval($j)) }
    elsif $c eq 's' { nqp::bindpos_s($a, $i, 's' ~ $j) }
    else            { nqp::bindpos($a, $i, 'o' ~ $j) }
    ''
}
sub psh($k, $a, int $j) {
    my $c := $k<cls>;
    if    $c eq 'i' || $c eq 'u' { nqp::push_i($a, ival($j)) }
    elsif $c eq 'n' { nqp::push_n($a, nval($j)) }
    elsif $c eq 's' { nqp::push_s($a, 's' ~ $j) }
    else            { nqp::push($a, 'o' ~ $j) }
    ''
}
sub ush($k, $a, int $j) {
    my $c := $k<cls>;
    if    $c eq 'i' || $c eq 'u' { nqp::unshift_i($a, ival($j)) }
    elsif $c eq 'n' { nqp::unshift_n($a, nval($j)) }
    elsif $c eq 's' { nqp::unshift_s($a, 's' ~ $j) }
    else            { nqp::unshift($a, 'o' ~ $j) }
    ''
}
sub pp($k, $a) {
    my $c := $k<cls>;
    if    $c eq 'i' || $c eq 'u' { ~nqp::pop_i($a) }
    elsif $c eq 'n' { ~nqp::pop_n($a) }
    elsif $c eq 's' { my str $s := nqp::pop_s($a); nqp::isnull_s($s) ?? '<null>' !! $s }
    else            { my $o := nqp::pop($a); nqp::isnull($o) ?? '<null>' !! ~$o }
}
sub shf($k, $a) {
    my $c := $k<cls>;
    if    $c eq 'i' || $c eq 'u' { ~nqp::shift_i($a) }
    elsif $c eq 'n' { ~nqp::shift_n($a) }
    elsif $c eq 's' { my str $s := nqp::shift_s($a); nqp::isnull_s($s) ?? '<null>' !! $s }
    else            { my $o := nqp::shift($a); nqp::isnull($o) ?? '<null>' !! ~$o }
}

# The whole array: element count and every element; an array above 40
# elements prints its count, the SHA-1 of the joined elements and both ends.
sub d($k, $a) {
    my int $e := nqp::elems($a);
    my @p := nqp::list_s();
    my int $i := 0;
    while $i < $e { nqp::push_s(@p, g($k, $a, $i)); $i++ }
    if $e <= 40 {
        "elems=$e [" ~ nqp::join(' ', @p) ~ ']'
    }
    else {
        "elems=$e sha1=" ~ nqp::sha1(nqp::join(' ', @p))
            ~ ' head=[' ~ nqp::atpos_s(@p, 0) ~ ' ' ~ nqp::atpos_s(@p, 1) ~ ' ' ~ nqp::atpos_s(@p, 2) ~ ']'
            ~ ' tail=[' ~ nqp::atpos_s(@p, $e - 3) ~ ' ' ~ nqp::atpos_s(@p, $e - 2) ~ ' ' ~ nqp::atpos_s(@p, $e - 1) ~ ']'
    }
}
# An array of $n elements, values 0 .. $n - 1, built by push.
sub fill($k, int $n) {
    my $a := mk($k);
    my int $j := 0;
    while $j < $n { psh($k, $a, $j); $j++ }
    $a
}
# The same contents with start > 0: $extra elements pushed first, then shifted.
sub fill_shifted($k, int $n, int $extra) {
    my $a := mk($k);
    my int $j := 0;
    while $j < $extra { psh($k, $a, 90 + $j); $j++ }
    $j := 0;
    while $j < $n { psh($k, $a, $j); $j++ }
    $j := 0;
    while $j < $extra { shf($k, $a); $j++ }
    $a
}

# ---------------------------------------------------- per-kind batteries

sub basics($k) {
    my $n := $k<name>;
    my $a := mk($k);
    t("$n.empty.elems",        { ~nqp::elems($a) });
    t("$n.empty.istrue",       { ~nqp::istrue($a) });
    t("$n.empty.islist",       { ~nqp::islist($a) });
    t("$n.empty.at0",          { g($k, $a, 0) });
    t("$n.empty.at5",          { g($k, $a, 5) });
    t("$n.empty.at-1",         { g($k, $a, -1) });
    t("$n.empty.pop",          { pp($k, $a) });
    t("$n.empty.shift",        { shf($k, $a) });
    t("$n.empty.bind-1",       { put($k, $a, -1, 1) ~ d($k, $a) });
    t("$n.empty.setelems0",    { nqp::setelems($a, 0); d($k, $a) });
    t("$n.empty.clone",        { d($k, nqp::clone($a)) });
    t("$n.empty.dump",         { d($k, $a) });

    t("$n.bind.0",             { put($k, $a, 0, 1) ~ d($k, $a) });
    t("$n.bind.gap5",          { put($k, $a, 5, 2) ~ d($k, $a) });
    t("$n.bind.-1",            { put($k, $a, -1, 3) ~ d($k, $a) });
    t("$n.bind.-6",            { put($k, $a, -6, 4) ~ d($k, $a) });
    t("$n.bind.-7",            { put($k, $a, -7, 5) ~ d($k, $a) });
    t("$n.bind.overwrite",     { put($k, $a, 5, 6) ~ d($k, $a) });
    t("$n.at.-1",              { g($k, $a, -1) });
    t("$n.at.-6",              { g($k, $a, -6) });
    t("$n.at.-7",              { g($k, $a, -7) });
    t("$n.at.past",            { g($k, $a, 6) ~ ' ' ~ g($k, $a, 1000000) });
    t("$n.at.gap",             { g($k, $a, 3) });
    t("$n.istrue",             { ~nqp::istrue($a) });

    $a := mk($k);
    my int $j := 0;
    while $j < 20 {
        my int $jj := $j;
        t("$n.push.$jj",       { psh($k, $a, $jj) ~ d($k, $a) });
        $j++;
    }
    t("$n.pop.1",              { pp($k, $a) ~ ' ' ~ d($k, $a) });
    t("$n.pop.2",              { pp($k, $a) ~ ' ' ~ d($k, $a) });
    t("$n.shift.1",            { shf($k, $a) ~ ' ' ~ d($k, $a) });
    t("$n.shift.2",            { shf($k, $a) ~ ' ' ~ d($k, $a) });
    t("$n.shift.3",            { shf($k, $a) ~ ' ' ~ d($k, $a) });
    t("$n.unshift.room",       { ush($k, $a, 30) ~ d($k, $a) });
    t("$n.unshift.room2",      { ush($k, $a, 31) ~ ush($k, $a, 32) ~ d($k, $a) });
    t("$n.unshift.grow",       { ush($k, $a, 33) ~ d($k, $a) });
    $j := 0;
    while $j < 30 { ush($k, $a, $j); $j++ }
    t("$n.unshift.many",       { d($k, $a) });
    t("$n.push.afterunshift",  { psh($k, $a, 40) ~ d($k, $a) });
    $j := 0;
    while $j < 50 { pp($k, $a); $j++ }
    t("$n.pop.to0",            { ~nqp::elems($a) ~ ' ' ~ ~nqp::istrue($a) });
    t("$n.pop.empty",          { pp($k, $a) });
    t("$n.shift.empty",        { shf($k, $a) });
    t("$n.push.afterempty",    { psh($k, $a, 1) ~ d($k, $a) });

    $a := mk($k);
    t("$n.unshift.empty",      { ush($k, $a, 1) ~ d($k, $a) });
    $j := 0;
    while $j < 8 { ush($k, $a, 2 + $j); $j++ }
    t("$n.unshift.9",          { d($k, $a) });
    t("$n.unshift.shiftall",   { my $s := ''; while nqp::elems($a) { $s := $s ~ shf($k, $a) ~ ' ' }; $s ~ d($k, $a) });
    t("$n.unshift.again",      { ush($k, $a, 5) ~ psh($k, $a, 6) ~ d($k, $a) });

    # Interleaved use as a queue: start advances, the storage is reused.
    $a := mk($k);
    t("$n.queue", {
        my int $q := 0;
        my $s := '';
        while $q < 200 {
            psh($k, $a, $q % 40); psh($k, $a, ($q + 1) % 40);
            $s := shf($k, $a);
            $q++;
        }
        $s ~ ' ' ~ d($k, $a)
    });
    t("$n.stack", {
        my int $q := 0;
        my $s := '';
        while $q < 200 {
            ush($k, $a, $q % 40); ush($k, $a, ($q + 1) % 40);
            $s := pp($k, $a);
            $q++;
        }
        $s ~ ' ' ~ d($k, $a)
    });
}

sub sizes($k) {
    my $n := $k<name>;
    my $a := fill($k, 5);
    t("$n.setelems.same",      { nqp::setelems($a, 5); d($k, $a) });
    t("$n.setelems.up8",       { nqp::setelems($a, 8); d($k, $a) });
    t("$n.setelems.up9",       { nqp::setelems($a, 9); d($k, $a) });
    t("$n.setelems.down3",     { nqp::setelems($a, 3); d($k, $a) });
    t("$n.setelems.up6",       { nqp::setelems($a, 6); d($k, $a) });
    t("$n.setelems.0",         { nqp::setelems($a, 0); d($k, $a) });
    t("$n.setelems.up4",       { nqp::setelems($a, 4); d($k, $a) });
    t("$n.setelems.fresh100",  { my $b := mk($k); nqp::setelems($b, 100); d($k, $b) });
    t("$n.setelems.fresh3",    { my $b := mk($k); nqp::setelems($b, 3); psh($k, $b, 1); d($k, $b) });

    # start > 0 and the request does not fit behind it: the elements move
    # back to the front of the storage.
    $a := fill($k, 8);
    t("$n.shiftback.shift",    { shf($k, $a) ~ ' ' ~ shf($k, $a) ~ ' ' ~ shf($k, $a) ~ ' ' ~ d($k, $a) });
    t("$n.shiftback.fits",     { psh($k, $a, 20) ~ psh($k, $a, 21) ~ psh($k, $a, 22) ~ d($k, $a) });
    t("$n.shiftback.move",     { psh($k, $a, 23) ~ d($k, $a) });
    t("$n.shiftback.more",     { psh($k, $a, 24) ~ psh($k, $a, 25) ~ psh($k, $a, 26) ~ d($k, $a) });
    $a := fill($k, 8);
    t("$n.shiftback.setelems", { shf($k, $a); shf($k, $a); nqp::setelems($a, 7); d($k, $a) });
    t("$n.shiftback.grow",     { shf($k, $a); nqp::setelems($a, 30); d($k, $a) });
    $a := fill($k, 8);
    t("$n.shiftback.bind",     { shf($k, $a); shf($k, $a); put($k, $a, 7, 30) ~ d($k, $a) });
    $a := fill($k, 8);
    t("$n.shiftback.shrink",   { shf($k, $a); shf($k, $a); nqp::setelems($a, 2); nqp::setelems($a, 6); d($k, $a) });
    $a := fill($k, 8);
    t("$n.shiftback.empty",    { my int $q := 0; while $q < 8 { shf($k, $a); $q++ }; nqp::setelems($a, 3); psh($k, $a, 1); d($k, $a) });

    # Shrinking clears the slots it gives up; growing again shows zeroes.
    $a := fill($k, 20);
    t("$n.shrinkgrow.pop",     { pp($k, $a); pp($k, $a); nqp::setelems($a, 20); d($k, $a) });
    t("$n.shrinkgrow.down",    { nqp::setelems($a, 2); nqp::setelems($a, 12); d($k, $a) });
    t("$n.shrinkgrow.bind",    { nqp::setelems($a, 1); put($k, $a, 4, 9) ~ d($k, $a) });

    # Growth through every branch of the policy.
    $a := mk($k);
    my int $j := 0;
    for (7, 8, 9, 16, 17, 100, 1000, 4095, 4096, 4097, 8191, 8192, 8193, 9000, 12288, 12289, 20000) -> $target {
        while $j < $target { psh($k, $a, $j % 40); $j++ }
        t("$n.grow.push.$target", { d($k, $a) });
    }
    t("$n.grow.shift100",      { my int $q := 0; my $s := ''; while $q < 100 { $s := shf($k, $a); $q++ }; $s ~ ' ' ~ d($k, $a) });
    $j := 0;
    while $j < 5000 { psh($k, $a, $j % 40); $j++ }
    t("$n.grow.pushshifted",   { d($k, $a) });
    t("$n.grow.setelems30000", { nqp::setelems($a, 30000); d($k, $a) });
    t("$n.grow.bind40000",     { put($k, $a, 40000, 7) ~ d($k, $a) });
    t("$n.grow.unshift",       { ush($k, $a, 8) ~ d($k, $a) });
    $j := 0;
    while $j < 9000 { ush($k, $a, $j % 40); $j++ }
    t("$n.grow.unshift9000",   { d($k, $a) });
    t("$n.grow.shrink3",       { nqp::setelems($a, 3); d($k, $a) });
    t("$n.grow.regrow10",      { nqp::setelems($a, 10); d($k, $a) });
    t("$n.grow.clone",         { my $c := nqp::clone($a); psh($k, $c, 1); d($k, $c) ~ ' / ' ~ d($k, $a) });

    $a := mk($k);
    t("$n.grow.setelems.steps", {
        my $s := '';
        for (1, 7, 8, 9, 17, 16, 33, 8191, 8192, 8193, 8192, 12289, 5, 16385, 0, 9) -> $target {
            nqp::setelems($a, $target);
            put($k, $a, -1, $target % 40) if $target;
            $s := $s ~ nqp::elems($a) ~ ':' ~ g($k, $a, 0) ~ ':' ~ ($target ?? g($k, $a, -1) !! '-') ~ ' ';
        }
        $s
    });
    $a := mk($k);
    t("$n.grow.bind.steps", {
        my $s := '';
        for (0, 7, 8, 100, 8191, 8192, 9000, 20000) -> $target {
            put($k, $a, $target, $target % 40);
            $s := $s ~ nqp::elems($a) ~ ':' ~ g($k, $a, $target - 1) ~ ':' ~ g($k, $a, -1) ~ ' ';
        }
        $s ~ nqp::sha1(d($k, $a))
    });
    $a := mk($k);
    t("$n.grow.unshift.steps", {
        my $s := '';
        my int $q := 0;
        for (1, 8, 9, 17, 100, 8192, 8193, 16500, 25000) -> $target {
            while $q < $target { ush($k, $a, $q % 40); $q++ }
            $s := $s ~ nqp::elems($a) ~ ':' ~ g($k, $a, 0) ~ ':' ~ g($k, $a, -1) ~ ' ';
        }
        $s ~ nqp::sha1(d($k, $a))
    });

    # The size limit. The message carries the slot count the policy computed.
    my $limit := $k<limit>;
    t("$n.limit.fresh",        { my $b := mk($k); nqp::setelems($b, $limit + 1); d($k, $b) });
    t("$n.limit.fresh-1",      { my $b := mk($k); nqp::setelems($b, -1); d($k, $b) });
    t("$n.limit.fresh-2",      { my $b := mk($k); nqp::setelems($b, -2); d($k, $b) });
    $a := fill($k, 5);
    t("$n.limit.small",        { nqp::setelems($a, $limit + 1); '' });
    t("$n.limit.small.after",  { d($k, $a) });
    t("$n.limit.small-1",      { nqp::setelems($a, -1); '' });
    t("$n.limit.small.usable", { psh($k, $a, 9) ~ d($k, $a) });
    $a := fill($k, 9000);
    t("$n.limit.large",        { nqp::setelems($a, $limit + 1); '' });
    t("$n.limit.large.after",  { d($k, $a) });
    t("$n.limit.large.usable", { psh($k, $a, 9) ~ d($k, $a) });
    $a := fill($k, 8);
    t("$n.limit.shifted",      { shf($k, $a); shf($k, $a); shf($k, $a); nqp::setelems($a, $limit + 1); '' });
    t("$n.limit.shifted.after", { d($k, $a) });
    t("$n.limit.shifted.usable", { psh($k, $a, 9) ~ ush($k, $a, 8) ~ d($k, $a) });
    if $k<esize> > 1 {
        $a := fill($k, 3);
        t("$n.limit.bind",       { put($k, $a, $limit, 1) });
        t("$n.limit.bind.after", { d($k, $a) });
    }
    $a := fill($k, 3);
    t("$n.limit.setdimensions", { nqp::setdimensions($a, nqp::list_i($limit + 1)); '' });
    t("$n.limit.splice",       { my $b := mk($k); nqp::setelems($b, 2); nqp::splice($a, $b, $limit, 0); '' });
    t("$n.limit.splice.after", { d($k, $a) });
}

sub splices($k) {
    my $n := $k<name>;
    my $src3 := fill_shifted($k, 3, 2);     # values 0 1 2, start 2
    my $empty := mk($k);
    sub sp($name, int $len, int $off, int $cnt, $from) {
        t("$n.splice.$name", { my $a := fill($k, $len); nqp::splice($a, $from, $off, $cnt); d($k, $a) });
        t("$n.splice.$name.shifted", { my $a := fill_shifted($k, $len, 3); nqp::splice($a, $from, $off, $cnt); d($k, $a) });
    }
    sp('insert.front',   6,  0, 0, $src3);
    sp('insert.middle',  6,  3, 0, $src3);
    sp('insert.end',     6,  6, 0, $src3);
    sp('insert.past',    6,  9, 0, $src3);
    sp('insert.neg',     6, -2, 0, $src3);
    sp('insert.neg6',    6, -6, 0, $src3);
    sp('insert.neg7',    6, -7, 0, $src3);
    sp('delete.front1',  6,  0, 1, $empty);
    sp('delete.front3',  6,  0, 3, $empty);
    sp('delete.all',     6,  0, 6, $empty);
    sp('delete.over',    6,  0, 9, $empty);
    sp('delete.middle',  6,  2, 2, $empty);
    sp('delete.tail',    6,  4, 2, $empty);
    sp('delete.tailover', 6, 4, 9, $empty);
    sp('delete.neg',     6, -3, 2, $empty);
    sp('delete.none',    6,  3, 0, $empty);
    sp('delete.past',    6,  8, 2, $empty);
    sp('replace.same',   6,  1, 3, $src3);
    sp('replace.shorter', 6, 1, 4, $src3);
    sp('replace.longer', 6,  1, 1, $src3);
    sp('replace.front.same',    6, 0, 3, $src3);
    sp('replace.front.shorter', 6, 0, 5, $src3);
    sp('replace.front.longer',  6, 0, 1, $src3);
    sp('replace.front.all',     6, 0, 6, $src3);
    sp('replace.front.over',    6, 0, 60, $src3);
    sp('replace.end',    6,  5, 1, $src3);
    sp('replace.endover', 6, 5, 9, $src3);
    sp('empty.insert',   0,  0, 0, $src3);
    sp('empty.delete',   0,  0, 3, $empty);
    sp('empty.past',     0,  4, 0, $src3);
    sp('empty.neg',      0, -1, 0, $src3);
    sp('one.replace',    1,  0, 1, $src3);
    sp('big.insert',  9000, 4500, 0, $src3);
    sp('big.delete',  9000, 10, 8000, $empty);
    sp('big.front',   9000,  0, 100, $src3);
    t("$n.splice.frombig", { my $a := fill($k, 6); nqp::splice($a, fill($k, 9000), 2, 2); d($k, $a) });
    t("$n.splice.fromhash", { my $a := fill($k, 6); nqp::splice($a, nqp::hash(), 1, 2); d($k, $a) });
    t("$n.splice.src.unchanged", { d($k, $src3) ~ ' / ' ~ d($k, $empty) });

    # Front splices on an array whose start is well above zero: the offset-0
    # branch moves start instead of the elements.
    sub spf($name, int $extra, int $cnt, int $srclen) {
        t("$n.splice.start.$name", {
            my $a := fill_shifted($k, 6, $extra);
            nqp::splice($a, fill($k, $srclen), 0, $cnt);
            my $r := d($k, $a);
            ush($k, $a, 30); psh($k, $a, 31);
            $r ~ ' / ' ~ d($k, $a)
        });
    }
    spf('grow.within',  5, 0, 3);
    spf('grow.exact',   5, 0, 5);
    spf('grow.beyond',  5, 0, 7);
    spf('grow.replace', 5, 2, 6);
    spf('shrink.1',     5, 1, 0);
    spf('shrink.5',     5, 5, 0);
    spf('shrink.6',     5, 6, 0);
    spf('shrink.7',     5, 7, 0);
    spf('shrink.repl',  5, 4, 2);
    spf('same',         5, 3, 3);

    # A splice from the array itself (Review Focus 3).
    sub selfsp($name, int $len, int $extra, int $off, int $cnt) {
        t("$n.selfsplice.$name", {
            my $a := $extra ?? fill_shifted($k, $len, $extra) !! fill($k, $len);
            nqp::splice($a, $a, $off, $cnt);
            d($k, $a)
        });
    }
    selfsp('prepend',        10, 0,  0,  0);
    selfsp('append',         10, 0, 10,  0);
    selfsp('middle',         10, 0,  5,  0);
    selfsp('middle1',        10, 0,  1,  0);
    selfsp('middle9',        10, 0,  9,  0);
    selfsp('replace.2.3',    10, 0,  2,  3);
    selfsp('replace.0.3',    10, 0,  0,  3);
    selfsp('replace.all',    10, 0,  0, 10);
    selfsp('replace.over',   10, 0,  0, 20);
    selfsp('replace.tail',   10, 0,  7,  3);
    selfsp('replace.5.5',    10, 0,  5,  5);
    selfsp('replace.1.9',    10, 0,  1,  9);
    selfsp('replace.1.20',   10, 0,  1, 20);
    selfsp('neg',            10, 0, -3,  1);
    selfsp('past',           10, 0, 12,  0);
    # A splice at offset 0 that grows an array with start > 0 moves start
    # back over slots that were shifted off, and a splice from the array
    # itself then copies what those slots still hold. For the numeric kinds
    # that is the old values; for OBJ and STR it is pointers the collector no
    # longer knows about, so those two kinds do not go there.
    unless $k<cls> eq 'o' || $k<cls> eq 's' {
        selfsp('shifted.prepend', 10, 4,  0,  0);
        selfsp('shifted.prepend20', 10, 20, 0, 0);
        selfsp('shifted.replace', 10, 4,  0,  4);
    }
    selfsp('shifted.middle', 10, 4,  5,  0);
    selfsp('shifted.replace.2.3', 10, 4, 2, 3);
    selfsp('shifted.append', 10, 4, 10,  0);
    selfsp('one',             1, 0,  0,  0);
    selfsp('one.replace',     1, 0,  0,  1);
    selfsp('empty',           0, 0,  0,  0);
    selfsp('big.middle',    9000, 0, 4500, 0);
    selfsp('big.1',         9000, 0,  1,  0);
    selfsp('big.replace',   9000, 0, 100, 5000);
    selfsp('big.shifted',   9000, 50, 3,  7);
    t("$n.selfsplice.twice", { my $a := fill($k, 4); nqp::splice($a, $a, 2, 1); nqp::splice($a, $a, 3, 0); d($k, $a) });
}

sub slices($k) {
    my $n := $k<name>;
    sub sl($name, int $len, int $extra, int $from, int $to) {
        t("$n.slice.$name", {
            my $a := $extra ?? fill_shifted($k, $len, $extra) !! fill($k, $len);
            my $s := nqp::slice($a, $from, $to);
            my $r := d($k, $s);
            psh($k, $s, 33); put($k, $s, 0, 34);
            $r ~ ' / ' ~ d($k, $s) ~ ' / ' ~ d($k, $a)
        });
    }
    sl('first',      6, 0,  0,  0);
    sl('1.3',        6, 0,  1,  3);
    sl('all',        6, 0,  0,  5);
    sl('all.neg',    6, 0,  0, -1);
    sl('last',       6, 0,  5,  5);
    sl('neg.neg',    6, 0, -3, -2);
    sl('neg.pos',    6, 0, -4,  4);
    sl('neg6',       6, 0, -6,  1);
    sl('neg7',       6, 0, -7,  1);
    sl('reversed',   6, 0,  3,  2);
    sl('end.past',   6, 0,  2,  6);
    sl('start.past', 6, 0,  6,  6);
    sl('end.neg7',   6, 0,  0, -7);
    sl('empty',      0, 0,  0,  0);
    sl('empty.neg',  0, 0,  0, -1);
    sl('one',        1, 0,  0,  0);
    sl('shifted',    6, 3,  1,  4);
    sl('shifted.all', 6, 3, 0, -1);
    sl('big',     9000, 0, 100, 8999);
    sl('big.shifted', 9000, 77, 4000, 4100);
    t("$n.slice.type", { my $a := fill($k, 3); my $s := nqp::slice($a, 0, 1); ~nqp::eqaddr(nqp::what($s), nqp::what($a)) });
}

sub clones($k) {
    my $n := $k<name>;
    t("$n.clone.plain", { my $a := fill($k, 5); my $c := nqp::clone($a); put($k, $c, 0, 30); psh($k, $a, 31); d($k, $c) ~ ' / ' ~ d($k, $a) });
    t("$n.clone.shifted", { my $a := fill_shifted($k, 5, 3); my $c := nqp::clone($a); ush($k, $c, 30); pp($k, $a); d($k, $c) ~ ' / ' ~ d($k, $a) });
    t("$n.clone.spare", { my $a := fill($k, 9); nqp::setelems($a, 2); my $c := nqp::clone($a); nqp::setelems($c, 5); d($k, $c) ~ ' / ' ~ d($k, $a) });
    t("$n.clone.emptied", { my $a := fill($k, 9); nqp::setelems($a, 0); my $c := nqp::clone($a); psh($k, $c, 1); d($k, $c) ~ ' / ' ~ d($k, $a) });
    t("$n.clone.big", { my $a := fill_shifted($k, 9000, 9); my $c := nqp::clone($a); shf($k, $c); d($k, $c) ~ ' / ' ~ d($k, $a) });
    t("$n.clone.type", { my $a := fill($k, 3); ~nqp::eqaddr(nqp::what(nqp::clone($a)), nqp::what($a)) });
}

sub multidim($k) {
    my $n := $k<name>;
    my $c := $k<cls>;
    my $a := fill_shifted($k, 4, 2);
    my $one := nqp::list_i(1);
    my $neg := nqp::list_i(-1);
    my $two := nqp::list_i(0, 1);
    my $none := nqp::list_i();
    sub atnd($idx) {
        if    $c eq 'i' { ~nqp::atposnd_i($a, $idx) }
        elsif $c eq 'u' { my uint $u := nqp::atposnd_u($a, $idx); my int $s := $u; ~$s }
        elsif $c eq 'n' { ~nqp::atposnd_n($a, $idx) }
        elsif $c eq 's' { sstr(nqp::atposnd_s($a, $idx)) }
        else            { ostr(nqp::atposnd($a, $idx)) }
    }
    sub bindnd($idx) {
        if    $c eq 'i' { nqp::bindposnd_i($a, $idx, 7) }
        elsif $c eq 'u' { my uint $u := 7; nqp::bindposnd_u($a, $idx, $u) }
        elsif $c eq 'n' { nqp::bindposnd_n($a, $idx, 7.5e0) }
        elsif $c eq 's' { nqp::bindposnd_s($a, $idx, 'nd') }
        else            { nqp::bindposnd($a, $idx, 'ond') }
        d($k, $a)
    }
    t("$n.nd.at.1",        { atnd($one) });
    t("$n.nd.at.neg",      { atnd($neg) });
    t("$n.nd.at.past",     { atnd(nqp::list_i(99)) });
    t("$n.nd.at.oob",      { atnd(nqp::list_i(-99)) });
    t("$n.nd.at.2",        { atnd($two) });
    t("$n.nd.at.0",        { atnd($none) });
    t("$n.nd.bind.1",      { bindnd($one) });
    t("$n.nd.bind.grow",   { bindnd(nqp::list_i(6)) });
    t("$n.nd.bind.oob",    { bindnd(nqp::list_i(-99)) });
    t("$n.nd.bind.2",      { bindnd($two) });
    t("$n.nd.bind.0",      { bindnd($none) });
    t("$n.nd.at2d", {
        if    $c eq 'i' { ~nqp::atpos2d_i($a, 0, 1) }
        elsif $c eq 'u' { my uint $u := nqp::atpos2d_u($a, 0, 1); my int $s := $u; ~$s }
        elsif $c eq 'n' { ~nqp::atpos2d_n($a, 0, 1) }
        elsif $c eq 's' { nqp::atpos2d_s($a, 0, 1) }
        else            { ~nqp::atpos2d($a, 0, 1) }
    });
    t("$n.nd.at3d", {
        if    $c eq 'i' { ~nqp::atpos3d_i($a, 0, 1, 2) }
        elsif $c eq 'u' { my uint $u := nqp::atpos3d_u($a, 0, 1, 2); my int $s := $u; ~$s }
        elsif $c eq 'n' { ~nqp::atpos3d_n($a, 0, 1, 2) }
        elsif $c eq 's' { nqp::atpos3d_s($a, 0, 1, 2) }
        else            { ~nqp::atpos3d($a, 0, 1, 2) }
    });
    t("$n.nd.bind2d", {
        if    $c eq 'i' { nqp::bindpos2d_i($a, 0, 1, 7) }
        elsif $c eq 'u' { my uint $u := 7; nqp::bindpos2d_u($a, 0, 1, $u) }
        elsif $c eq 'n' { nqp::bindpos2d_n($a, 0, 1, 7.5e0) }
        elsif $c eq 's' { nqp::bindpos2d_s($a, 0, 1, 'nd') }
        else            { nqp::bindpos2d($a, 0, 1, 'ond') }
        d($k, $a)
    });
    t("$n.nd.bind3d", {
        if    $c eq 'i' { nqp::bindpos3d_i($a, 0, 1, 2, 7) }
        elsif $c eq 'u' { my uint $u := 7; nqp::bindpos3d_u($a, 0, 1, 2, $u) }
        elsif $c eq 'n' { nqp::bindpos3d_n($a, 0, 1, 2, 7.5e0) }
        elsif $c eq 's' { nqp::bindpos3d_s($a, 0, 1, 2, 'nd') }
        else            { nqp::bindpos3d($a, 0, 1, 2, 'ond') }
        d($k, $a)
    });
    t("$n.nd.dimensions",  { my $dims := nqp::dimensions($a); nqp::elems($dims) ~ ' ' ~ nqp::atpos_i($dims, 0) });
    t("$n.nd.numdimensions", { ~nqp::numdimensions($a) });
    t("$n.nd.setdimensions.1", { nqp::setdimensions($a, nqp::list_i(3)); d($k, $a) });
    t("$n.nd.setdimensions.up", { nqp::setdimensions($a, nqp::list_i(9)); d($k, $a) });
    t("$n.nd.setdimensions.2", { nqp::setdimensions($a, nqp::list_i(2, 2)); d($k, $a) });
    t("$n.nd.setdimensions.0", { nqp::setdimensions($a, $none); d($k, $a) });
    t("$n.nd.dimensions.after", { my $dims := nqp::dimensions($a); nqp::elems($dims) ~ ' ' ~ nqp::atpos_i($dims, 0) });
    t("$n.nd.dimensions.empty", { my $dims := nqp::dimensions(mk($k)); nqp::elems($dims) ~ ' ' ~ nqp::atpos_i($dims, 0) });
}

# write_buf and read_buf: nqp::writeint/writeuint/writenum and
# nqp::readint/readuint/readnum. The flags are endianness (0 native, 1 little,
# 2 big) plus 4 times log2 of the size in bytes. The offset counts elements,
# the size counts bytes.
sub bytes_of($k, $a) {
    # The storage as the bytes read_buf returns, one element at a time.
    my int $e := nqp::elems($a);
    my int $f := $k<esize> == 8 ?? 12 !! $k<esize> == 4 ?? 8 !! $k<esize> == 2 ?? 4 !! 0;
    my @p := nqp::list_s();
    my int $i := 0;
    while $i < $e { nqp::push_s(@p, ~nqp::readint($a, $i, $f + 1)); $i++ }
    "elems=$e [" ~ nqp::join(' ', @p) ~ ']'
}
sub bufs($k) {
    my $n := $k<name>;
    my $ref := $k<cls> eq 'o' || $k<cls> eq 's';
    sub dd($a) { $ref ?? d($k, $a) !! bytes_of($k, $a) }
    for (0, 1, 2) -> $endian {
        for (0, 4, 8, 12) -> $sz {
            my int $flags := $endian + $sz;
            t("$n.buf.writeint.f$flags", { my $a := fill($k, 3); nqp::writeint($a, 1, 0x0102030405060788, $flags); dd($a) });
            t("$n.buf.writeint.neg.f$flags", { my $a := fill($k, 3); nqp::writeint($a, 0, -2, $flags); dd($a) });
            t("$n.buf.writeuint.f$flags", { my $a := fill($k, 3); my uint $u := 0xF1E2D3C4B5A69788; nqp::writeuint($a, 2, $u, $flags); dd($a) });
            t("$n.buf.writeint.grow.f$flags", { my $a := fill($k, 3); nqp::writeint($a, 5, 0x1122334455667788, $flags); dd($a) });
            t("$n.buf.writeint.end.f$flags", { my $a := fill($k, 3); nqp::writeint($a, 3, 0x1122334455667788, $flags); dd($a) });
            t("$n.buf.writeint.empty.f$flags", { my $a := mk($k); nqp::writeint($a, 0, 0x1122334455667788, $flags); dd($a) });
            t("$n.buf.writeint.shifted.f$flags", { my $a := fill_shifted($k, 3, 2); nqp::writeint($a, 2, 0x1122334455667788, $flags); dd($a) });
            t("$n.buf.readint.f$flags", {
                my $a := mk($k); nqp::setelems($a, 10);
                nqp::writeint($a, 0, 0x8182838485868788, 13) unless $ref;
                nqp::writeint($a, 9, 0x8182838485868788, 13) unless $ref;
                my uint $u := nqp::readuint($a, 0, $flags); my int $s := $u;
                nqp::readint($a, 0, $flags) ~ ' ' ~ $s ~ ' ' ~ nqp::readint($a, 9, $flags)
            });
            t("$n.buf.readint.last.f$flags", { my $a := fill($k, 8); nqp::setelems($a, 4); ~nqp::readint($a, 3, $flags) });
            t("$n.buf.readint.past.f$flags", { my $a := fill($k, 8); nqp::setelems($a, 4); ~nqp::readint($a, 4, $flags) });
            t("$n.buf.readint.empty.f$flags", { ~nqp::readint(mk($k), 0, $flags) });
        }
        for (8, 12) -> $sz {
            my int $flags := $endian + $sz;
            t("$n.buf.writenum.f$flags", { my $a := fill($k, 3); nqp::writenum($a, 1, 0.1e0, $flags); dd($a) });
            t("$n.buf.writenum.nan.f$flags", { my $a := fill($k, 3); nqp::writenum($a, 0, nqp::nan(), $flags); nqp::writenum($a, 2, -0e0, $flags); dd($a) });
            t("$n.buf.writenum.grow.f$flags", { my $a := fill($k, 3); nqp::writenum($a, 4, -1.5e0, $flags); dd($a) });
            t("$n.buf.readnum.f$flags", { my $a := mk($k); nqp::setelems($a, 10); nqp::writenum($a, 0, 0.1e0, $flags); nqp::writenum($a, 9, -2.5e0, $flags); nqp::readnum($a, 0, $flags) ~ ' ' ~ nqp::readnum($a, 9, $flags) });
            t("$n.buf.readnum.past.f$flags", { my $a := fill($k, 4); ~nqp::readnum($a, 4, $flags) });
        }
    }
    t("$n.buf.writeint.negoffset", { my $a := fill($k, 3); nqp::writeint($a, -1, 5, 1); dd($a) });
    t("$n.buf.readint.negoffset", { my $a := fill($k, 3); ~nqp::readint($a, -1, 1) });
    t("$n.buf.readint.far", { my $a := fill($k, 3); ~nqp::readint($a, 1000, 13) });
    t("$n.buf.writeint.far", { my $a := fill($k, 3); nqp::writeint($a, 9000, 5, 1); nqp::elems($a) ~ ' ' ~ nqp::readint($a, 9000, 1) ~ ' ' ~ nqp::readint($a, 8999, 1) });
    t("$n.buf.flags.3", { my $a := fill($k, 3); nqp::writeint($a, 0, 5, 3); dd($a) });
    t("$n.buf.flags.16", { my $a := fill($k, 3); nqp::writeint($a, 0, 5, 16); dd($a) });
    t("$n.buf.readflags.3", { my $a := fill($k, 3); ~nqp::readint($a, 0, 3) });
    t("$n.buf.readnum.size1", { my $a := fill($k, 3); ~nqp::readnum($a, 0, 0) });
    # The bounds check of read_buf adds start to the element count, so with
    # start > 0 it lets a read past the last element through. These reads
    # stay inside the storage (5 pushed, storage of 8, 2 shifted off).
    t("$n.buf.readint.shifted.in", { my $a := fill_shifted($k, 3, 2); ~nqp::readint($a, 2, 1) });
    t("$n.buf.readint.shifted.past1", { my $a := fill_shifted($k, 3, 2); ~nqp::readint($a, 3, 1) });
    t("$n.buf.readint.shifted.past2", { my $a := fill_shifted($k, 3, 2); ~nqp::readint($a, 4, 1) });
    t("$n.buf.readint.shifted.past3", { my $a := fill_shifted($k, 3, 2); ~nqp::readint($a, 5, 1) });
    t("$n.buf.writeint.limit", { my $a := fill($k, 3); nqp::writeint($a, $k<limit>, 5, 1); dd($a) });
}

# Every typed operation on every kind, including the register kinds the slot
# kind rejects, with the state the array is left in.
sub mismatches($k) {
    my $n := $k<name>;
    my $ref := $k<cls> eq 'o' || $k<cls> eq 's';
    sub m($name, &code) {
        t("$n.kind.$name", { my $a := fill($k, 3); my $r := code($a); $r ~ ' / ' ~ d($k, $a) });
        t("$n.kind.$name.shifted", { my $a := fill_shifted($k, 3, 2); my $r := code($a); $r ~ ' / ' ~ d($k, $a) });
        t("$n.kind.$name.state", {
            my $a := fill($k, 3);
            try { code($a); CATCH { } }
            # What the failed operation left: for the numeric kinds, grow
            # back over the slots; for the reference kinds only use the array.
            nqp::setelems($a, 6) unless $ref;
            psh($k, $a, 30); ush($k, $a, 31);
            d($k, $a)
        });
        t("$n.kind.$name.empty", { my $a := mk($k); my $r := code($a); $r ~ ' / ' ~ d($k, $a) });
    }
    m('atpos_o',     -> $a { ostr(nqp::atpos($a, 1)) });
    m('atpos_i',     -> $a { ~nqp::atpos_i($a, 1) });
    m('atpos_u',     -> $a { my uint $u := nqp::atpos_u($a, 1); my int $s := $u; ~$s });
    m('atpos_n',     -> $a { ~nqp::atpos_n($a, 1) });
    m('atpos_s',     -> $a { sstr(nqp::atpos_s($a, 1)) });
    m('atpos_o.past', -> $a { ostr(nqp::atpos($a, 7)) });
    m('atpos_i.past', -> $a { ~nqp::atpos_i($a, 7) });
    m('atpos_u.past', -> $a { my uint $u := nqp::atpos_u($a, 7); my int $s := $u; ~$s });
    m('atpos_n.past', -> $a { ~nqp::atpos_n($a, 7) });
    m('atpos_s.past', -> $a { sstr(nqp::atpos_s($a, 7)) });
    m('atpos_o.oob', -> $a { ostr(nqp::atpos($a, -7)) });
    m('atpos_i.oob', -> $a { ~nqp::atpos_i($a, -7) });
    m('atpos_u.oob', -> $a { my uint $u := nqp::atpos_u($a, -7); my int $s := $u; ~$s });
    m('atpos_n.oob', -> $a { ~nqp::atpos_n($a, -7) });
    m('atpos_s.oob', -> $a { sstr(nqp::atpos_s($a, -7)) });
    m('bindpos_o',   -> $a { nqp::bindpos($a, 1, 'ob'); '' });
    m('bindpos_i',   -> $a { nqp::bindpos_i($a, 1, 7); '' });
    m('bindpos_u',   -> $a { my uint $u := 7; nqp::bindpos_u($a, 1, $u); '' });
    m('bindpos_n',   -> $a { nqp::bindpos_n($a, 1, 7.5e0); '' });
    m('bindpos_s',   -> $a { nqp::bindpos_s($a, 1, 'sb'); '' });
    m('bindpos_o.grow', -> $a { nqp::bindpos($a, 5, 'ob'); '' });
    m('bindpos_i.grow', -> $a { nqp::bindpos_i($a, 5, 7); '' });
    m('bindpos_u.grow', -> $a { my uint $u := 7; nqp::bindpos_u($a, 5, $u); '' });
    m('bindpos_n.grow', -> $a { nqp::bindpos_n($a, 5, 7.5e0); '' });
    m('bindpos_s.grow', -> $a { nqp::bindpos_s($a, 5, 'sb'); '' });
    m('bindpos_o.oob', -> $a { nqp::bindpos($a, -7, 'ob'); '' });
    m('bindpos_i.oob', -> $a { nqp::bindpos_i($a, -7, 7); '' });
    m('bindpos_u.oob', -> $a { my uint $u := 7; nqp::bindpos_u($a, -7, $u); '' });
    m('bindpos_n.oob', -> $a { nqp::bindpos_n($a, -7, 7.5e0); '' });
    m('bindpos_s.oob', -> $a { nqp::bindpos_s($a, -7, 'sb'); '' });
    m('push_o',      -> $a { nqp::push($a, 'op'); '' });
    m('push_i',      -> $a { nqp::push_i($a, 7); '' });
    m('push_n',      -> $a { nqp::push_n($a, 7.5e0); '' });
    m('push_s',      -> $a { nqp::push_s($a, 'sp'); '' });
    m('pop_o',       -> $a { ostr(nqp::pop($a)) });
    m('pop_i',       -> $a { ~nqp::pop_i($a) });
    m('pop_n',       -> $a { ~nqp::pop_n($a) });
    m('pop_s',       -> $a { sstr(nqp::pop_s($a)) });
    m('shift_o',     -> $a { ostr(nqp::shift($a)) });
    m('shift_i',     -> $a { ~nqp::shift_i($a) });
    m('shift_n',     -> $a { ~nqp::shift_n($a) });
    m('shift_s',     -> $a { sstr(nqp::shift_s($a)) });
    m('unshift_o',   -> $a { nqp::unshift($a, 'ou'); '' });
    m('unshift_i',   -> $a { nqp::unshift_i($a, 7); '' });
    m('unshift_n',   -> $a { nqp::unshift_n($a, 7.5e0); '' });
    m('unshift_s',   -> $a { nqp::unshift_s($a, 'su'); '' });
    m('existspos',   -> $a { nqp::existspos($a, 1) ~ ' ' ~ nqp::existspos($a, -1) ~ ' ' ~ nqp::existspos($a, 3) ~ ' ' ~ nqp::existspos($a, -4) });
    m('join',        -> $a { nqp::join(',', $a) });
    m('iterator', -> $a {
        my $it := nqp::iterator($a);
        my $c := $k<cls>;
        my $s := '';
        while $it {
            if    $c eq 'i' || $c eq 'u' { $s := $s ~ nqp::shift_i($it) ~ ' ' }
            elsif $c eq 'n' { $s := $s ~ nqp::shift_n($it) ~ ' ' }
            elsif $c eq 's' { $s := $s ~ nqp::shift_s($it) ~ ' ' }
            else            { $s := $s ~ nqp::shift($it) ~ ' ' }
        }
        $s
    });
    m('iterator.o', -> $a { my $it := nqp::iterator($a); my $s := ''; while $it { $s := $s ~ ostr(nqp::shift($it)) ~ ' ' }; $s });
    m('iterator.i', -> $a { my $it := nqp::iterator($a); my $s := ''; while $it { $s := $s ~ nqp::shift_i($it) ~ ' ' }; $s });
    m('iterator.n', -> $a { my $it := nqp::iterator($a); my $s := ''; while $it { $s := $s ~ nqp::shift_n($it) ~ ' ' }; $s });
    m('iterator.s', -> $a { my $it := nqp::iterator($a); my $s := ''; while $it { $s := $s ~ sstr(nqp::shift_s($it)) ~ ' ' }; $s });
    m('for',         -> $a { my $s := ''; for $a { $s := $s ~ $_ ~ ' ' }; $s });
    m('flatten',     -> $a { flat_args(|$a) });
    m('flatten.typed', -> $a {
        my $c := $k<cls>;
        $c eq 'i' || $c eq 'u' ?? flat_i(|$a) !! $c eq 'n' ?? flat_n(|$a) !! $c eq 's' ?? flat_s(|$a) !! flat_args(|$a)
    });
    t("$n.kind.elemspec", {
        my $ty := $k<type>;
        nqp::objprimspec($ty) ~ ' ' ~ nqp::objprimbits($ty) ~ ' ' ~ nqp::objprimunsigned($ty)
    });
    t("$n.kind.reprname", { nqp::reprname(mk($k)) ~ ' ' ~ nqp::islist(mk($k)) ~ ' ' ~ nqp::isconcrete($k<type>) });
}
sub flat_args(*@a) { my $s := nqp::elems(@a) ~ ':'; for @a { $s := $s ~ $_ ~ ',' }; $s }
sub flat_i(int $a, int $b, int $c) { "$a,$b,$c" }
sub flat_n(num $a, num $b, num $c) { "$a,$b,$c" }
sub flat_s(str $a, str $b, str $c) { "$a,$b,$c" }

# Review Focus 2: what each integer kind stores and gives back at and around
# its limits, and what the num kinds do with special and unrepresentable
# values, through every write path and every read path.
sub hex(int $v) {
    my $s := '';
    my int $i := 0;
    my int $x := $v;
    while $i < 16 {
        $s := nqp::substr('0123456789abcdef', nqp::bitand_i($x, 15), 1) ~ $s;
        $x := nqp::bitshiftr_i($x, 4);
        $i++;
    }
    $s
}
sub int_values() {
    my $l := nqp::list_i(0, 1, -1, 127, 128, 255, 256, -128, -129,
        32767, 32768, 65535, 65536, -32768, -32769,
        2147483647, 2147483648, 4294967295, 4294967296, -2147483648, -2147483649,
        9223372036854775807, -9223372036854775807, 1311768467463790320);
    nqp::push_i($l, nqp::bitshiftl_i(1, 63));        # 2**63 as bits
    nqp::push_i($l, nqp::bitshiftl_i(1, 63) + 1);
    nqp::push_i($l, -2);                             # 2**64 - 2 as bits
    $l
}
sub values_int($k) {
    my $n := $k<name>;
    my $vals := int_values();
    my int $count := nqp::elems($vals);
    my int $i := 0;
    while $i < $count {
        my int $v := nqp::atpos_i($vals, $i);
        my uint $uv := $v;
        my $unsigned := $k<cls> eq 'u';
        my int $ii := $i;
        t("$n.value.$ii.$v", {
            my $a := mk($k);
            nqp::bindpos_i($a, 0, $v);
            if $unsigned { nqp::bindpos_u($a, 1, $uv) } else { nqp::bindpos_i($a, 1, $v) }
            nqp::push_i($a, $v);
            nqp::unshift_i($a, $v);
            nqp::bindposnd_i($a, nqp::list_i(4), $v);
            nqp::writeint($a, 5, $v, 13);
            nqp::splice($a, nqp::list_i($v), 6, 0);
            my $r := '';
            my int $j := 0;
            while $j < 7 {
                my int $us := nqp::atpos_i($a, $j);
                if $unsigned { my uint $u := nqp::atpos_u($a, $j); $us := $u }
                $r := $r ~ nqp::atpos_i($a, $j) ~ '/' ~ hex($us) ~ ' ';
                $j++;
            }
            $r := $r ~ 'nd=' ~ nqp::atposnd_i($a, nqp::list_i(4));
            $r := $r ~ ' clone=' ~ nqp::atpos_i(nqp::clone($a), 0);
            $r := $r ~ ' slice=' ~ nqp::atpos_i(nqp::slice($a, 0, 0), 0);
            $r := $r ~ ' flat=' ~ flat_args(|nqp::slice($a, 0, 0));
            my $it := nqp::iterator($a);
            $r := $r ~ ' iter=' ~ nqp::shift_i($it);
            my $b := mk($k);
            nqp::push_i($b, $v); nqp::unshift_i($b, $v);
            $r := $r ~ ' pop=' ~ nqp::pop_i($b) ~ ' shift=' ~ nqp::shift_i($b) ~ ' left=' ~ nqp::elems($b);
            $r
        });
        $i++;
    }
}
sub values_num($k) {
    my $n := $k<name>;
    my $vals := nqp::list_n(0e0, -0e0, 1e0, -1e0, nqp::nan(), nqp::inf(), nqp::neginf(),
        0.1e0, nqp::div_n(1e0, 3e0), 16777216e0, 16777217e0, 16777219e0,
        3.4028234663852886e38, 3.4028235677973362e38, 3.4028235677973366e38, 3.5e38, 1e39, -1e39,
        1.401298464324817e-45, 7.006492321624085e-46, 7.1e-46, 1e-46, -1e-46,
        1.1754943508222875e-38, 1.7976931348623157e308, 5e-324, 2.2250738585072014e-308,
        9007199254740993e0, 123456789.123456789e0);
    my int $count := nqp::elems($vals);
    my int $f := $k<esize> == 8 ?? 13 !! 9;
    my int $i := 0;
    while $i < $count {
        my num $v := nqp::atpos_n($vals, $i);
        my int $ii := $i;
        t("$n.value.$ii." ~ $v, {
            my $a := mk($k);
            nqp::bindpos_n($a, 0, $v);
            nqp::push_n($a, $v);
            nqp::unshift_n($a, $v);
            nqp::bindposnd_n($a, nqp::list_i(3), $v);
            nqp::splice($a, nqp::list_n($v), 4, 0);
            my $r := '';
            my int $j := 0;
            while $j < 5 {
                $r := $r ~ nqp::atpos_n($a, $j) ~ '/' ~ hex(nqp::readuint($a, $j, $f)) ~ ' ';
                $j++;
            }
            $r := $r ~ 'nd=' ~ nqp::atposnd_n($a, nqp::list_i(3));
            $r := $r ~ ' clone=' ~ nqp::atpos_n(nqp::clone($a), 0);
            $r := $r ~ ' slice=' ~ nqp::atpos_n(nqp::slice($a, 0, 0), 0);
            $r := $r ~ ' flat=' ~ flat_args(|nqp::slice($a, 0, 0));
            my $it := nqp::iterator($a);
            $r := $r ~ ' iter=' ~ nqp::shift_n($it);
            my $b := mk($k);
            nqp::push_n($b, $v); nqp::unshift_n($b, $v);
            $r := $r ~ ' pop=' ~ nqp::pop_n($b) ~ ' shift=' ~ nqp::shift_n($b) ~ ' left=' ~ nqp::elems($b);
            $r
        });
        $i++;
    }
}

# A splice from an array of another numeric kind. copy_elements reads the
# source with the source's register kind and binds with the target's, with
# no coercion between them, so an int source lands in a num target as bits.
sub numeric_dump($k, $a) {
    $k<cls> eq 'n' ?? d($k, $a) ~ ' ' ~ bytes_of($k, $a) !! d($k, $a)
}
sub cross_splices() {
    my @numeric := nqp::list('i64', 'i32', 'i16', 'i8', 'u64', 'u32', 'u16', 'u8', 'n64', 'n32');
    for @numeric -> $dn {
        my $dk := kind_named($dn);
        for @numeric -> $sn {
            my $sk := kind_named($sn);
            t("cross.splice.$dn.from.$sn", {
                my $src := mk($sk);
                if $sk<cls> eq 'n' {
                    nqp::push_n($src, 1.5e0); nqp::push_n($src, -2e0); nqp::push_n($src, 1e39); nqp::push_n($src, 0.1e0);
                }
                else {
                    nqp::push_i($src, -1); nqp::push_i($src, 300); nqp::push_i($src, 70000);
                    nqp::push_i($src, 1311768467463790320); nqp::push_i($src, 4607182418800017408);
                }
                nqp::shift_i($src) if $sk<cls> ne 'n';
                nqp::unshift_i($src, -1) if $sk<cls> ne 'n';
                my $dst := fill($dk, 4);
                nqp::splice($dst, $src, 1, 2);
                numeric_dump($dk, $dst)
            });
            t("cross.slice.$dn.from.$sn", {
                # The same pair through a second array type of the same kind
                # (another STable): the same-slot-type fast path.
                my $src := fill_shifted($sk, 4, 2);
                my $dst := fill($dk, 2);
                nqp::splice($dst, nqp::slice($src, 1, 2), 2, 0);
                numeric_dump($dk, $dst)
            });
        }
    }
    # Same slot kind, different array types.
    my $i64b := arrtype(inttype(64, 0));
    my $n64b := arrtype(numtype(64));
    my $strb := arrtype(str);
    my $objb := nqp::newtype(nqp::null(), 'VMArray');
    t('cross.same.i64', { my $a := nqp::list_i(1, 2, 3); my $b := nqp::create($i64b); nqp::push_i($b, 8); nqp::push_i($b, 9); nqp::splice($a, $b, 1, 1); nqp::splice($b, $a, 0, 0); d(kind_named('i64'), $a) ~ ' / ' ~ d(kind_named('i64'), $b) });
    t('cross.same.n64', { my $a := nqp::list_n(1e0, 2e0, 3e0); my $b := nqp::create($n64b); nqp::push_n($b, 8.5e0); nqp::splice($a, $b, 1, 1); nqp::splice($b, $a, 0, 0); d(kind_named('n64'), $a) ~ ' / ' ~ d(kind_named('n64'), $b) });
    t('cross.same.str', { my $a := nqp::list_s('a', 'b', 'c'); my $b := nqp::create($strb); nqp::push_s($b, 'x'); nqp::push_s($b, 'y'); nqp::splice($a, $b, 1, 1); nqp::splice($b, $a, 0, 0); d(kind_named('str'), $a) ~ ' / ' ~ d(kind_named('str'), $b) });
    t('cross.same.obj', { my $a := nqp::list('a', 'b', 'c'); my $b := nqp::create($objb); nqp::push($b, 'x'); nqp::push($b, 'y'); nqp::splice($a, $b, 1, 1); nqp::splice($b, $a, 0, 0); d(kind_named('obj'), $a) ~ ' / ' ~ d(kind_named('obj'), $b) });
    t('cross.literal.list',   { d(kind_named('obj'), nqp::list('a', 'b', 'c')) ~ ' ' ~ d(kind_named('obj'), nqp::list()) });
    t('cross.literal.list_i', { d(kind_named('i64'), nqp::list_i(1, -2, 3)) ~ ' ' ~ d(kind_named('i64'), nqp::list_i()) });
    t('cross.literal.list_n', { d(kind_named('n64'), nqp::list_n(1.5e0, -2e0)) ~ ' ' ~ d(kind_named('n64'), nqp::list_n()) });
    t('cross.literal.list_s', { d(kind_named('str'), nqp::list_s('a', 'b')) ~ ' ' ~ d(kind_named('str'), nqp::list_s()) });
}

# The kinds without storage: an element type of 4, 2 or 1 bits composes to a
# slot kind with an element size of zero, and every arm that switches on the
# slot kind takes its default.
sub odd_kinds() {
    for (4, 2, 1) -> $bits {
        for (0, 1) -> $unsigned {
            my $n := ($unsigned ?? 'u' !! 'i') ~ $bits;
            my $ty := arrtype(inttype($bits, $unsigned));
            my $a := nqp::create($ty);
            t("$n.odd.elems",      { ~nqp::elems($a) });
            t("$n.odd.atpos_i",    { ~nqp::atpos_i($a, 0) });
            t("$n.odd.atpos_u",    { my uint $u := nqp::atpos_u($a, 0); my int $s := $u; ~$s });
            t("$n.odd.atpos_o",    { ~nqp::isnull(nqp::atpos($a, 0)) });
            t("$n.odd.atpos_n",    { ~nqp::atpos_n($a, 0) });
            t("$n.odd.atpos_s",    { nqp::atpos_s($a, 0) });
            t("$n.odd.atpos.oob",  { ~nqp::atpos_i($a, -1) });
            t("$n.odd.bindpos_i",  { nqp::bindpos_i($a, 0, 1); ~nqp::elems($a) });
            t("$n.odd.bindpos.again", { nqp::bindpos_i($a, 3, 1); ~nqp::elems($a) });
            t("$n.odd.bindpos.oob", { nqp::bindpos_i($a, -1, 1); ~nqp::elems($a) });
            t("$n.odd.push_i",     { nqp::push_i($a, 1); ~nqp::elems($a) });
            t("$n.odd.push_o",     { nqp::push($a, 'x'); ~nqp::elems($a) });
            t("$n.odd.pop_i",      { ~nqp::pop_i($a) });
            t("$n.odd.shift_i",    { ~nqp::shift_i($a) });
            t("$n.odd.unshift_i",  { nqp::unshift_i($a, 1); ~nqp::elems($a) });
            t("$n.odd.setelems.0", { nqp::setelems($a, 0); ~nqp::elems($a) });
            t("$n.odd.setelems.3", { nqp::setelems($a, 3); ~nqp::elems($a) });
            t("$n.odd.setelems.limit", { nqp::setelems($a, nqp::bitshiftl_i(1, 63) + 1); ~nqp::elems($a) });
            t("$n.odd.setelems.-1", { nqp::setelems($a, -1); ~nqp::elems($a) });
            t("$n.odd.splice.empty", { nqp::splice($a, nqp::list_i(), 0, 0); ~nqp::elems($a) });
            t("$n.odd.splice.delete", { nqp::splice($a, nqp::list_i(), 0, 2); ~nqp::elems($a) });
            t("$n.odd.splice.insert", { nqp::splice($a, nqp::list_i(1), 0, 0); ~nqp::elems($a) });
            t("$n.odd.splice.self", { nqp::splice($a, $a, 0, 0); ~nqp::elems($a) });
            t("$n.odd.slice",      { ~nqp::elems(nqp::slice($a, 0, 0)) });
            t("$n.odd.clone",      { ~nqp::elems(nqp::clone($a)) });
            t("$n.odd.writeint",   { nqp::writeint($a, 0, 1, 1); ~nqp::elems($a) });
            t("$n.odd.readint",    { ~nqp::readint($a, 0, 1) });
            t("$n.odd.join",       { '[' ~ nqp::join(',', $a) ~ ']' });
            t("$n.odd.iterator",   { my $it := nqp::iterator($a); ~nqp::istrue($it) });
            t("$n.odd.flatten",    { flat_args(|$a) });
            t("$n.odd.existspos",  { ~nqp::existspos($a, 0) });
            t("$n.odd.dimensions", { my $dims := nqp::dimensions($a); nqp::elems($dims) ~ ' ' ~ nqp::atpos_i($dims, 0) });
            t("$n.odd.setdimensions", { nqp::setdimensions($a, nqp::list_i(2)); ~nqp::elems($a) });
            t("$n.odd.atposnd",    { ~nqp::atposnd_i($a, nqp::list_i(0)) });
            t("$n.odd.istrue",     { ~nqp::istrue($a) });
            t("$n.odd.elems.end",  { ~nqp::elems($a) });
        }
    }
    # What compose accepts and rejects as an element type.
    t('compose.num16',   { arrtype(numtype(16)); 'composed' });
    t('compose.int3',    { arrtype(inttype(3, 0)); 'composed' });
    t('compose.uint128', { arrtype(inttype(128, 1)); 'composed' });
    t('compose.bigint',  {
        my $a := nqp::create(arrtype(nqp::newtype(nqp::null(), 'P6bigint')));
        nqp::push_i($a, -5); nqp::atpos_i($a, 0) ~ ' ' ~ nqp::elems($a)
    });
    t('compose.str',     { my $a := nqp::create(arrtype(str)); nqp::push_s($a, 'x'); nqp::atpos_s($a, 0) });
    t('compose.int',     { my $a := nqp::create(arrtype(int)); nqp::push_i($a, -5); ~nqp::atpos_i($a, 0) });
    t('compose.num',     { my $a := nqp::create(arrtype(num)); nqp::push_n($a, -5.5e0); ~nqp::atpos_n($a, 0) });
    t('compose.object',  { my $a := nqp::create(arrtype(NQPMu)); nqp::push($a, 'x'); ~nqp::atpos($a, 0) });
    t('compose.notype',  {
        my $ty := nqp::newtype(nqp::null(), 'VMArray');
        nqp::composetype($ty, nqp::hash('array', nqp::hash()));
        my $a := nqp::create($ty); nqp::push($a, 'x'); ~nqp::atpos($a, 0)
    });
    t('compose.noarray', {
        my $ty := nqp::newtype(nqp::null(), 'VMArray');
        nqp::composetype($ty, nqp::hash());
        my $a := nqp::create($ty); nqp::push($a, 'x'); ~nqp::atpos($a, 0)
    });
    t('compose.twice',   {
        my $ty := arrtype(inttype(8, 0));
        nqp::composetype($ty, nqp::hash('array', nqp::hash('type', inttype(16, 1))));
        my $a := nqp::create($ty); nqp::push_i($a, -1); ~nqp::atpos_i($a, 0)
    });
    t('typeobject.elems', { ~nqp::elems(nqp::what(nqp::list_i())) });
    t('typeobject.atpos', { ~nqp::isnull(nqp::atpos(nqp::what(nqp::list()), 0)) });
    t('typeobject.push',  { nqp::push_i(nqp::what(nqp::list_i()), 1); '' });
    t('typeobject.clone', { ~nqp::isconcrete(nqp::clone(nqp::what(nqp::list_i()))) });
}

# An array type composed a second time while an array of it is alive: the
# array keeps its elements and storage and gets the new slot kind. Going from
# int8 (one byte a slot) to a 4-bit or 1-bit element type (no storage, element
# size zero) is the one way to hold a non-empty array of a kind without
# storage, and so the one way into the default arms of bind_pos, push, pop,
# shift, unshift and serialize. Nothing here reads or writes a slot: with an
# element size of zero every copy is of zero bytes. (A splice that would copy
# elements into such an array is absent: slot_type_to_kind aborts the process.)
sub recomposed() {
    for (4, 1) -> $bits {
        for (1, 0) -> $unsigned {
            my $n := ($unsigned ?? 'u' !! 'i') ~ $bits ~ '.recomposed';
            # 1 4 7 in an int8 array (storage of 8), with start 0 or 2.
            sub mkre(int $shifted) {
                my $ty := arrtype(inttype(8, 0));
                my $a := nqp::create($ty);
                if $shifted { nqp::push_i($a, 90); nqp::push_i($a, 91) }
                nqp::push_i($a, 1); nqp::push_i($a, 4); nqp::push_i($a, 7);
                if $shifted { nqp::shift_i($a); nqp::shift_i($a) }
                nqp::composetype($ty, nqp::hash('array', nqp::hash('type', inttype($bits, $unsigned))));
                $a
            }
            sub re($name, &code) {
                t("$n.$name", { my $a := mkre(0); my $r := code($a); $r ~ ' / elems=' ~ nqp::elems($a) });
                t("$n.$name.after", { my $a := mkre(0); try { code($a); CATCH { } }; 'elems=' ~ nqp::elems($a) });
                t("$n.$name.shifted", { my $a := mkre(1); my $r := code($a); $r ~ ' / elems=' ~ nqp::elems($a) });
                t("$n.$name.shifted.after", { my $a := mkre(1); try { code($a); CATCH { } }; 'elems=' ~ nqp::elems($a) });
            }
            re('elems',        -> $a { ~nqp::elems($a) });
            re('atpos_i',      -> $a { ~nqp::atpos_i($a, 0) });
            re('atpos_i.past', -> $a { ~nqp::atpos_i($a, 9) });
            re('atpos_i.oob',  -> $a { ~nqp::atpos_i($a, -4) });
            re('atpos_o',      -> $a { ostr(nqp::atpos($a, 0)) });
            re('bindpos_i',    -> $a { nqp::bindpos_i($a, 0, 1); '' });
            re('bindpos_i.neg', -> $a { nqp::bindpos_i($a, -1, 1); '' });
            re('bindpos_i.oob', -> $a { nqp::bindpos_i($a, -4, 1); '' });
            re('bindpos_i.spare', -> $a { nqp::bindpos_i($a, 4, 1); '' });
            re('bindpos_i.grow', -> $a { nqp::bindpos_i($a, 20, 1); '' });
            re('bindpos_o',    -> $a { nqp::bindpos($a, 0, 'x'); '' });
            re('push_i',       -> $a { nqp::push_i($a, 1); '' });
            re('push_s',       -> $a { nqp::push_s($a, 'x'); '' });
            re('push_i.many',  -> $a { my $s := ''; my int $q := 0; while $q < 8 { try { nqp::push_i($a, 1); CATCH { $s := $s ~ nqp::getmessage($!) ~ ';' } }; $q++ }; $s });
            re('pop_i',        -> $a { ~nqp::pop_i($a) });
            re('pop_i.all',    -> $a { my $s := ''; my int $q := 0; while $q < 5 { try { nqp::pop_i($a); CATCH { $s := $s ~ nqp::getmessage($!) ~ ';' } }; $q++ }; $s });
            re('shift_i',      -> $a { ~nqp::shift_i($a) });
            re('unshift_i',    -> $a { nqp::unshift_i($a, 1); '' });
            re('unshift_i.many', -> $a { my $s := ''; my int $q := 0; while $q < 4 { try { nqp::unshift_i($a, 1); CATCH { $s := $s ~ nqp::getmessage($!) ~ ';' } }; $q++ }; $s });
            re('setelems.down', -> $a { nqp::setelems($a, 1); '' });
            re('setelems.spare', -> $a { nqp::setelems($a, 5); '' });
            re('setelems.grow', -> $a { nqp::setelems($a, 50); '' });
            re('setelems.same', -> $a { nqp::setelems($a, 3); '' });
            re('splice.delete', -> $a { nqp::splice($a, nqp::list_i(), 0, 1); '' });
            re('splice.delete.tail', -> $a { nqp::splice($a, nqp::list_i(), 1, 2); '' });
            re('slice',        -> $a { ~nqp::elems(nqp::slice($a, 0, 1)) });
            re('clone',        -> $a { my $c := nqp::clone($a); nqp::elems($c) ~ ' ' ~ nqp::reprname($c) });
            re('readint',      -> $a { ~nqp::readint($a, 0, 1) });
            re('join',         -> $a { nqp::join(',', $a) });
            re('existspos',    -> $a { ~nqp::existspos($a, 0) });
            re('flatten',      -> $a { flat_args(|$a) });
            re('iterator',     -> $a { my $it := nqp::iterator($a); ~nqp::shift_i($it) });
            re('iterator.o',   -> $a { my $it := nqp::iterator($a); ostr(nqp::shift($it)) });
            re('atposnd',      -> $a { ~nqp::atposnd_i($a, nqp::list_i(0)) });
            re('bindposnd',    -> $a { nqp::bindposnd_i($a, nqp::list_i(0), 1); '' });
            re('dimensions',   -> $a { ~nqp::atpos_i(nqp::dimensions($a), 0) });
            re('gc',           -> $a { nqp::force_gc(); ~nqp::elems($a) });
        }
    }
    # Between two kinds with storage of the same element size the array is
    # simply read as the new kind.
    t('recomposed.i8.u8', {
        my $ty := arrtype(inttype(8, 0));
        my $a := nqp::create($ty);
        nqp::push_i($a, -1); nqp::push_i($a, 100);
        nqp::composetype($ty, nqp::hash('array', nqp::hash('type', inttype(8, 1))));
        nqp::push_i($a, -2);
        nqp::atpos_i($a, 0) ~ ' ' ~ nqp::atpos_i($a, 1) ~ ' ' ~ nqp::atpos_i($a, 2) ~ ' ' ~ nqp::elems($a)
    });
    t('recomposed.i64.n64', {
        my $ty := arrtype(inttype(64, 0));
        my $a := nqp::create($ty);
        nqp::push_i($a, 4607182418800017408); nqp::push_i($a, -1);
        nqp::composetype($ty, nqp::hash('array', nqp::hash('type', numtype(64))));
        nqp::push_n($a, 2.5e0);
        nqp::atpos_n($a, 0) ~ ' ' ~ nqp::atpos_n($a, 1) ~ ' ' ~ nqp::atpos_n($a, 2) ~ ' ' ~ nqp::elems($a)
    });
}
# Serializing a non-empty array of a kind without storage: the default arm of
# serialize. Run last: the serializer does not clean up after an exception.
sub recomposed_serialize() {
    t('u4.recomposed.serialize', {
        my $ty := arrtype(inttype(8, 0));
        my $a := nqp::create($ty);
        nqp::push_i($a, 1); nqp::push_i($a, 4);
        nqp::composetype($ty, nqp::hash('array', nqp::hash('type', inttype(4, 1))));
        my $sc := nqp::createsc('VA_DIFF_RECOMPOSED');
        nqp::scsetobj($sc, 0, $a);
        nqp::setobjsc($a, $sc);
        nqp::serialize($sc, nqp::list_s());
        'serialized'
    });
}

# The collector's view: the mark of OBJ and STR arrays (from start, over
# elems), binds into arrays that have been promoted, and a splice into a
# promoted array (the path of copy_elements that takes the write barrier).
sub gc_cases() {
    for ('obj', 'str') -> $kn {
        my $k := kind_named($kn);
        my $young := fill_shifted($k, 30, 7);
        my $old := fill_shifted($k, 30, 7);
        nqp::force_gc(); nqp::force_gc(); nqp::force_gc();
        t("$kn.gc.survive", { d($k, $old) });
        my int $j := 0;
        while $j < 40 { psh($k, $old, $j + 5); ush($k, $old, $j + 6); put($k, $old, 3, $j); $j++ }
        nqp::force_gc();
        t("$kn.gc.barrier", { d($k, $old) });
        nqp::splice($old, fill($k, 20), 4, 2);
        nqp::splice($old, $old, 5, 0);
        nqp::force_gc();
        t("$kn.gc.splice.promoted", { d($k, $old) });
        t("$kn.gc.slice.promoted", { my $s := nqp::slice($old, 3, 20); nqp::force_gc(); d($k, $s) });
        t("$kn.gc.clone.promoted", { my $c := nqp::clone($old); nqp::force_gc(); psh($k, $c, 1); d($k, $c) });
        t("$kn.gc.selfsplice.promoted", { my $a := fill($k, 10); nqp::force_gc(); nqp::force_gc(); nqp::force_gc(); nqp::splice($a, $a, 5, 0); d($k, $a) });
        t("$kn.gc.young", { d($k, $young) });
        t("$kn.gc.big", {
            my $a := mk($k);
            my int $q := 0;
            while $q < 30000 { psh($k, $a, $q % 1000); $q++ }
            $q := 0;
            while $q < 10000 { shf($k, $a); $q++ }
            nqp::force_gc();
            $q := 0;
            while $q < 30000 { ush($k, $a, $q % 1000); $q++ }
            nqp::force_gc(); nqp::force_gc();
            d($k, $a)
        });
    }
    for ('i64', 'u8', 'n32') -> $kn {
        my $k := kind_named($kn);
        my $old := fill_shifted($k, 30, 7);
        nqp::force_gc(); nqp::force_gc(); nqp::force_gc();
        t("$kn.gc.survive", { psh($k, $old, 2); ush($k, $old, 3); d($k, $old) });
    }
    t('gc.many', {
        # Arrays allocated and dropped, so their storage is freed.
        my int $q := 0;
        my int $sum := 0;
        while $q < 20000 {
            my $a := nqp::list_i(1, 2, 3);
            nqp::push_i($a, $q);
            my $b := nqp::list_s('a');
            my $c := nqp::list($a, $b);
            $sum := $sum + nqp::elems($a) + nqp::elems($b) + nqp::elems($c);
            $q++;
        }
        ~$sum
    });
}

# Hot loops: with spesh enabled these run specialized and compiled, where an
# elems on a known array becomes a field read, a create becomes a fast
# create, and atpos_i/bindpos_i/atpos_u/bindpos_u on a known I64 or U64 array
# call the array's two devirtualized functions (see also vmarray-devirt.nqp).
sub hot_int($a, int $rounds) {
    my int $e := nqp::elems($a);
    my int $sum := 0;
    my int $i := 0;
    while $i < $rounds {
        nqp::bindpos_i($a, $i % $e, $i);
        nqp::bindpos_i($a, -1 - (($i + 3) % $e), $i + 1);
        $sum := $sum + nqp::atpos_i($a, ($i + 5) % $e) + nqp::atpos_i($a, -1 - ($i % $e))
            + nqp::atpos_i($a, $e + ($i % 3)) + nqp::elems($a);
        $i++;
    }
    $sum
}
sub hot_uint($a, int $rounds) {
    my int $e := nqp::elems($a);
    my int $sum := 0;
    my int $i := 0;
    while $i < $rounds {
        my uint $v := $i;
        nqp::bindpos_u($a, $i % $e, $v);
        nqp::bindpos_u($a, -1 - (($i + 3) % $e), $v);
        my uint $r := nqp::atpos_u($a, ($i + 5) % $e);
        my uint $q := nqp::atpos_u($a, -1 - ($i % $e));
        my uint $p := nqp::atpos_u($a, $e + ($i % 3));
        my int $ri := $r; my int $qi := $q; my int $pi := $p;
        $sum := $sum + $ri + $qi + $pi + nqp::elems($a);
        $i++;
    }
    $sum
}
sub hot_num($a, int $rounds) {
    my int $e := nqp::elems($a);
    my num $sum := 0e0;
    my int $i := 0;
    while $i < $rounds {
        nqp::bindpos_n($a, $i % $e, $i + 0.5e0);
        $sum := $sum + nqp::atpos_n($a, ($i + 5) % $e) + nqp::atpos_n($a, -1 - ($i % $e)) + nqp::atpos_n($a, $e + 1);
        $i++;
    }
    $sum
}
sub hot_str($a, int $rounds) {
    my int $e := nqp::elems($a);
    my int $sum := 0;
    my int $i := 0;
    while $i < $rounds {
        nqp::bindpos_s($a, $i % $e, ~($i % 100));
        $sum := $sum + nqp::chars(nqp::atpos_s($a, ($i + 5) % $e)) + nqp::isnull_s(nqp::atpos_s($a, $e + 1));
        $i++;
    }
    $sum
}
sub hot_obj($a, int $rounds) {
    my int $e := nqp::elems($a);
    my int $sum := 0;
    my int $i := 0;
    while $i < $e { nqp::bindpos($a, $i, $a); $i++ }
    $i := 0;
    while $i < $rounds {
        nqp::bindpos($a, $i % $e, $a);
        $sum := $sum + nqp::elems(nqp::atpos($a, ($i + 5) % $e)) + nqp::isnull(nqp::atpos($a, $e + 1));
        $i++;
    }
    $sum
}
sub hot_grow($type, int $rounds) {
    my int $sum := 0;
    my int $i := 0;
    while $i < $rounds {
        my $a := nqp::create($type);
        nqp::push_i($a, $i); nqp::push_i($a, $i + 1); nqp::unshift_i($a, $i + 2);
        $sum := $sum + nqp::elems($a) + nqp::pop_i($a) + nqp::shift_i($a) + nqp::atpos_i($a, 0);
        $i++;
    }
    $sum
}
sub hot_at_i($a, int $i) { nqp::atpos_i($a, $i) }
sub hot_bind_i($a, int $i) { nqp::bindpos_i($a, $i, 5); nqp::elems($a) }
sub hot_at_u($a, int $i) { my uint $u := nqp::atpos_u($a, $i); my int $s := $u; $s }
sub hot_bind_u($a, int $i) { my uint $u := 5; nqp::bindpos_u($a, $i, $u); nqp::elems($a) }
# The same five reads through subs that see every kind in turn, so that the
# compiled code has no type to specialize on and calls MVM_repr_at_pos_*,
# which reach the array's MVM_VMArray_at_pos_s/_i/_u/_n/_o entry points; those
# word their errors differently from MVM_VMArray_at_pos. A case prints the
# distinct results in order of first appearance, not when they changed.
sub mega_o($a, int $i) { ostr(nqp::atpos($a, $i)) }
sub mega_i($a, int $i) { ~nqp::atpos_i($a, $i) }
sub mega_u($a, int $i) { my uint $u := nqp::atpos_u($a, $i); my int $s := $u; ~$s }
sub mega_n($a, int $i) { ~nqp::atpos_n($a, $i) }
sub mega_s($a, int $i) { sstr(nqp::atpos_s($a, $i)) }
sub mega_cases() {
    my @arrs;
    my @seen;
    for @kinds -> $k { nqp::push(@arrs, fill_shifted($k, 4, 2)); nqp::push(@seen, nqp::list_s()) }
    my int $nk := nqp::elems(@kinds);
    for ('o', 'i', 'u', 'n', 's') -> $op {
        for (1, -1, 9, -9) -> $idx {
            my int $round := 0;
            for @seen { nqp::setelems($_, 0) }
            while $round < 3000 {
                my int $ki := 0;
                while $ki < $nk {
                    my $a := @arrs[$ki];
                    my $r;
                    try {
                        $r := $op eq 'o' ?? mega_o($a, $idx) !! $op eq 'i' ?? mega_i($a, $idx)
                           !! $op eq 'u' ?? mega_u($a, $idx) !! $op eq 'n' ?? mega_n($a, $idx) !! mega_s($a, $idx);
                        CATCH { $r := 'DIED ' ~ nqp::getmessage($!) }
                    }
                    my $s := @seen[$ki];
                    my int $have := 0;
                    my int $j := 0;
                    while $j < nqp::elems($s) { $have := 1 if nqp::atpos_s($s, $j) eq $r; $j++ }
                    nqp::push_s($s, $r) unless $have;
                    $ki++;
                }
                $round++;
            }
            my int $ki := 0;
            while $ki < $nk {
                say(@kinds[$ki]<name> ~ ".mega.atpos_$op.$idx: " ~ nqp::join(' | ', @seen[$ki]));
                $ki++;
            }
        }
    }
}

# The same, with the last round out of bounds, so that the error is raised
# from inside the running loop, in compiled code. (The array is an argument
# here, and compiled code that does not know an argument's type calls
# MVM_repr_at_pos_i and MVM_repr_bind_pos_i; the errors of the two
# devirtualized functions are the business of vmarray-devirt.nqp.)
sub hot_oob_at_i($a, int $rounds, int $bad) {
    my int $e := nqp::elems($a);
    my int $sum := 0;
    my int $i := 0;
    while $i < $rounds { $sum := $sum + nqp::atpos_i($a, $i == $rounds - 1 ?? $bad !! $i % $e); $i++ }
    $sum
}
sub hot_oob_bind_i($a, int $rounds, int $bad) {
    my int $e := nqp::elems($a);
    my int $i := 0;
    while $i < $rounds { nqp::bindpos_i($a, $i == $rounds - 1 ?? $bad !! $i % $e, $i); $i++ }
    nqp::elems($a)
}
sub hot_oob_at_u($a, int $rounds, int $bad) {
    my int $e := nqp::elems($a);
    my int $sum := 0;
    my int $i := 0;
    while $i < $rounds { my uint $u := nqp::atpos_u($a, $i == $rounds - 1 ?? $bad !! $i % $e); my int $s := $u; $sum := $sum + $s; $i++ }
    $sum
}
sub hot_oob_bind_u($a, int $rounds, int $bad) {
    my int $e := nqp::elems($a);
    my int $i := 0;
    while $i < $rounds { my uint $u := $i; nqp::bindpos_u($a, $i == $rounds - 1 ?? $bad !! $i % $e, $u); $i++ }
    nqp::elems($a)
}
sub hot_cases() {
    my int $rounds := 300000;
    for @kinds -> $k {
        my $n := $k<name>;
        my $c := $k<cls>;
        t("$n.hot.loop", {
            my $a := fill($k, 50);
            if    $c eq 'i' { ~hot_int($a, $rounds) }
            elsif $c eq 'u' { ~hot_uint($a, $rounds) ~ ' ' ~ hot_int($a, $rounds) }
            elsif $c eq 'n' { ~hot_num($a, $rounds) }
            elsif $c eq 's' { ~hot_str($a, $rounds) }
            else            { ~hot_obj($a, $rounds) }
        });
        if $c eq 'i' || $c eq 'u' {
            t("$n.hot.grow", { ~hot_grow($k<type>, $rounds) });
        }
    }
    # Small subs called hot with one array type, then out of bounds.
    for ('i64', 'u64', 'i8', 'u16') -> $kn {
        my $k := kind_named($kn);
        my $a := fill($k, 10);
        my $u := $k<cls> eq 'u';
        t("$kn.hot.sub", {
            my int $i := 0;
            my int $sum := 0;
            while $i < 100000 {
                $sum := $sum + hot_at_i($a, $i % 12) + hot_at_i($a, -1 - ($i % 10)) + hot_bind_i($a, $i % 10) + hot_bind_i($a, -1 - ($i % 10));
                $sum := $sum + hot_at_u($a, $i % 12) + hot_at_u($a, -1 - ($i % 10)) + hot_bind_u($a, $i % 10) + hot_bind_u($a, -1 - ($i % 10)) if $u;
                $i++;
            }
            ~$sum
        });
        t("$kn.hot.sub.at_i.oob",   { ~hot_at_i($a, -11) });
        t("$kn.hot.sub.bind_i.oob", { ~hot_bind_i($a, -11) });
        t("$kn.hot.sub.at_u.oob",   { ~hot_at_u($a, -11) });
        t("$kn.hot.sub.bind_u.oob", { ~hot_bind_u($a, -11) });
        t("$kn.hot.sub.bind_i.grow", { ~hot_bind_i($a, 20000) });
        t("$kn.hot.sub.bind_u.grow", { ~hot_bind_u($a, 40000) });
        t("$kn.hot.sub.after", { nqp::sha1(d($k, $a)) });
        for (-11, 10, 50000) -> $bad {
            t("$kn.hot.loop.at_i.$bad",   { my $b := fill($k, 10); ~hot_oob_at_i($b, 200000, $bad) });
            t("$kn.hot.loop.bind_i.$bad", { my $b := fill($k, 10); ~hot_oob_bind_i($b, 200000, $bad) });
            if $u {
                t("$kn.hot.loop.at_u.$bad",   { my $b := fill($k, 10); ~hot_oob_at_u($b, 200000, $bad) });
                t("$kn.hot.loop.bind_u.$bad", { my $b := fill($k, 10); ~hot_oob_bind_u($b, 200000, $bad) });
            }
        }
    }
}

# ------------------------------------------------------------------ main

for @kinds -> $k { basics($k) }
for @kinds -> $k { sizes($k) }
for @kinds -> $k { splices($k) }
for @kinds -> $k { slices($k) }
for @kinds -> $k { clones($k) }
for @kinds -> $k { multidim($k) }
for @kinds -> $k { bufs($k) }
for @kinds -> $k { mismatches($k) }
for @kinds -> $k {
    if    $k<cls> eq 'i' || $k<cls> eq 'u' { values_int($k) }
    elsif $k<cls> eq 'n' { values_num($k) }
}
cross_splices();
odd_kinds();
gc_cases();
hot_cases();
mega_cases();
recomposed();
recomposed_serialize();
say('done: 1');
