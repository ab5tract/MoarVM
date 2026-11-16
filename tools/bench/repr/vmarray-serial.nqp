# The VMArray serialization record (spec
# traces/llm/specs/2026-11-16-zig-vmarray-repr-design.md, section 7 item 3).
#
# Serializes one serialization context per case, each holding one VMArray:
# an empty, a 3-element, a shifted (start > 0) and a 10,000-element array of
# every kind nqp can construct (nqp::list, nqp::list_i, nqp::list_n,
# nqp::list_s) and of every typed kind made with nqp::newtype(..., 'VMArray')
# and nqp::composetype with an 'array' hash naming a sized P6int or P6num
# element type (int and uint of 8, 16, 32 and 64 bits, num of 32 and 64, and
# str), plus an empty array of a 4-bit element type, which serializes and
# then fails to deserialize.
#
# Without arguments it prints, per case,
#     <case>.blob: <the serialized bytes as hex>
#     <case>.strings: <count> <the string heap, '|'-separated>
#     <case>.roundtrip: <the array deserialized in this process>
# With --read=FILE, where FILE is the output of another run (of this or of
# another build), it deserializes each case's blob with its string heap and
# prints
#     <case>.read: <the array's contents>
# in the format of the .roundtrip lines, so that
#     sed -n 's/\.roundtrip: /.read: /p' FILE
# is what a correct reader prints. A caught exception prints DIED and its
# message in place of the contents. The reader gives each context the handle
# the writer gave it and must see the cases in the writer's order, because a
# case may refer to a type that an earlier case's context holds.
#
# The bytes come from nqp::serializetobuf into a uint8 VMArray (which is the
# array's write_buf at work); the reader feeds nqp::deserialize the same bytes
# as base64. Nothing in the output varies from run to run.
#
# Run: <prefix>/bin/nqp-m tools/bench/repr/vmarray-serial.nqp [--read=FILE]

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

my $buf8 := arrtype(inttype(8, 1));

# ------------------------------------------------------------ hex and base64

my str $hexdigits := '0123456789abcdef';
sub buf_to_hex($buf) {
    my @p := nqp::list_s();
    my int $n := nqp::elems($buf);
    my int $i := 0;
    while $i < $n {
        my int $b := nqp::atpos_i($buf, $i);
        nqp::push_s(@p, nqp::substr($hexdigits, nqp::bitshiftr_i($b, 4), 1) ~ nqp::substr($hexdigits, nqp::bitand_i($b, 15), 1));
        $i++;
    }
    nqp::join('', @p)
}
sub hex_to_buf(str $hex) {
    my $buf := nqp::create($buf8);
    my int $n := nqp::chars($hex);
    my int $i := 0;
    while $i < $n {
        nqp::push_i($buf, nqp::index($hexdigits, nqp::substr($hex, $i, 1)) * 16 + nqp::index($hexdigits, nqp::substr($hex, $i + 1, 1)));
        $i := $i + 2;
    }
    $buf
}
my str $b64 := 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
sub buf_to_base64($buf) {
    my @p := nqp::list_s();
    my int $n := nqp::elems($buf);
    my int $i := 0;
    while $i < $n {
        my int $left := $n - $i;
        my int $c := nqp::atpos_i($buf, $i) * 65536;
        $c := $c + nqp::atpos_i($buf, $i + 1) * 256 if $left > 1;
        $c := $c + nqp::atpos_i($buf, $i + 2) if $left > 2;
        nqp::push_s(@p, nqp::substr($b64, nqp::bitand_i(nqp::bitshiftr_i($c, 18), 63), 1));
        nqp::push_s(@p, nqp::substr($b64, nqp::bitand_i(nqp::bitshiftr_i($c, 12), 63), 1));
        nqp::push_s(@p, $left > 1 ?? nqp::substr($b64, nqp::bitand_i(nqp::bitshiftr_i($c, 6), 63), 1) !! '=');
        nqp::push_s(@p, $left > 2 ?? nqp::substr($b64, nqp::bitand_i($c, 63), 1) !! '=');
        $i := $i + 3;
    }
    nqp::join('', @p)
}

# ------------------------------------------------------------------ the cases

# Register class per kind name: how the elements are written and read.
sub cls_of(str $kind) {
    $kind eq 'list' || $kind eq 'obj' ?? 'o'
        !! $kind eq 'list_s' || $kind eq 'str' ?? 's'
        !! $kind eq 'list_n' || nqp::eqat($kind, 'n', 0) ?? 'n'
        !! 'i'
}
# The value of element $j: integers spread over every width of the variable
# length encoding and both signs; nums with a fraction; strings that repeat
# (the string heap holds each once); objects that are strings, integers,
# nested arrays and nulls.
sub ival(int $j) { nqp::bitshiftl_i($j - 4000, $j % 53) + $j }
sub nval(int $j) { nqp::div_n(nqp::mul_n($j - 4000, 37e0), 8e0) }
sub put($a, str $cls, int $j) {
    if    $cls eq 'i' { nqp::push_i($a, ival($j)) }
    elsif $cls eq 'n' { nqp::push_n($a, nval($j)) }
    elsif $cls eq 's' { nqp::push_s($a, 's' ~ ($j % 700)) }
    else {
        my int $m := $j % 5;
        if    $m == 0 { nqp::push($a, 'o' ~ ($j % 300)) }
        elsif $m == 1 { nqp::push($a, $j) }
        elsif $m == 2 { nqp::push($a, nqp::list_i($j, -$j)) }
        elsif $m == 3 { nqp::push($a, nqp::null()) }
        else          { nqp::push($a, nqp::list_s('n' ~ $j)) }
    }
}
sub build($type, str $cls, str $size) {
    my $a := nqp::create($type);
    if $size eq '3' {
        if $cls eq 'i' {
            nqp::push_i($a, -1); nqp::push_i($a, 1311768467463790320); nqp::push_i($a, nqp::bitshiftl_i(1, 63));
        }
        elsif $cls eq 'n' {
            nqp::push_n($a, nqp::nan()); nqp::push_n($a, -0e0); nqp::push_n($a, 1e39);
        }
        elsif $cls eq 's' {
            nqp::push_s($a, 'first'); nqp::setelems($a, 2); nqp::push_s($a, 'third');
        }
        else {
            nqp::push($a, 'first'); nqp::setelems($a, 2); nqp::push($a, nqp::list_n(0.5e0));
        }
    }
    elsif $size eq 'shifted' {
        # Seven pushed, two shifted off the front, one popped: start is 2 and
        # the storage holds more than the four elements left.
        my int $j := 0;
        while $j < 7 { put($a, $cls, $j * 611); $j++ }
        if $cls eq 'i' { nqp::shift_i($a); nqp::shift_i($a); nqp::pop_i($a) }
        elsif $cls eq 'n' { nqp::shift_n($a); nqp::shift_n($a); nqp::pop_n($a) }
        elsif $cls eq 's' { nqp::shift_s($a); nqp::shift_s($a); nqp::pop_s($a) }
        else { nqp::shift($a); nqp::shift($a); nqp::pop($a) }
    }
    elsif $size eq '10000' {
        my int $j := 0;
        while $j < 10000 { put($a, $cls, $j); $j++ }
    }
    $a
}

sub ostr($o) {
    if nqp::isnull($o) { '<null>' }
    elsif nqp::islist($o) {
        my $spec := nqp::elems($o) ?? '' !! 'empty';
        my @p := nqp::list_s();
        my $it := nqp::iterator($o);
        # A nested array is a list_i or a list_s here; tell them apart by trying.
        my int $e := nqp::elems($o);
        my int $i := 0;
        while $i < $e {
            my $v;
            try { $v := ~nqp::atpos_i($o, $i); CATCH { $v := nqp::null() } }
            if nqp::isnull($v) { try { $v := nqp::atpos_s($o, $i); CATCH { $v := nqp::null() } } }
            if nqp::isnull($v) { try { $v := ~nqp::atpos_n($o, $i); CATCH { $v := '?' } } }
            nqp::push_s(@p, $v);
            $i++;
        }
        '(' ~ nqp::join(',', @p) ~ ')'
    }
    else { ~$o }
}
sub dump($a, str $cls) {
    my int $e := nqp::elems($a);
    my @p := nqp::list_s();
    my int $i := 0;
    while $i < $e {
        if    $cls eq 'i' { nqp::push_s(@p, ~nqp::atpos_i($a, $i)) }
        elsif $cls eq 'n' { nqp::push_s(@p, ~nqp::atpos_n($a, $i)) }
        elsif $cls eq 's' { my str $s := nqp::atpos_s($a, $i); nqp::push_s(@p, nqp::isnull_s($s) ?? '<null>' !! $s) }
        else              { nqp::push_s(@p, ostr(nqp::atpos($a, $i))) }
        $i++;
    }
    my $r := nqp::reprname($a) ~ " elems=$e ";
    if $e <= 40 {
        $r := $r ~ '[' ~ nqp::join(' ', @p) ~ ']';
    }
    else {
        $r := $r ~ 'sha1=' ~ nqp::sha1(nqp::join(' ', @p))
            ~ ' head=[' ~ nqp::atpos_s(@p, 0) ~ ' ' ~ nqp::atpos_s(@p, 1) ~ ' ' ~ nqp::atpos_s(@p, 2) ~ ']'
            ~ ' tail=[' ~ nqp::atpos_s(@p, $e - 3) ~ ' ' ~ nqp::atpos_s(@p, $e - 2) ~ ' ' ~ nqp::atpos_s(@p, $e - 1) ~ ']';
    }
    # The array must still work as an array of its kind after deserialization.
    if    $cls eq 'i' { nqp::push_i($a, 7); nqp::unshift_i($a, 8); $r := $r ~ ' +' ~ nqp::atpos_i($a, 0) ~ ',' ~ nqp::atpos_i($a, -1) }
    elsif $cls eq 'n' { nqp::push_n($a, 7.5e0); nqp::unshift_n($a, 8.5e0); $r := $r ~ ' +' ~ nqp::atpos_n($a, 0) ~ ',' ~ nqp::atpos_n($a, -1) }
    elsif $cls eq 's' { nqp::push_s($a, 'p'); nqp::unshift_s($a, 'u'); $r := $r ~ ' +' ~ nqp::atpos_s($a, 0) ~ ',' ~ nqp::atpos_s($a, -1) }
    else              { nqp::push($a, 'p'); nqp::unshift($a, 'u'); $r := $r ~ ' +' ~ nqp::atpos($a, 0) ~ ',' ~ nqp::atpos($a, -1) }
    $r ~ ' elems=' ~ nqp::elems($a)
}

# Deserializes one case into a context with the given handle and returns the
# contents of its array (object 0).
sub read_case(str $handle, str $cls, str $hex, @strings) {
    my $r;
    try {
        my $dsc := nqp::createsc($handle);
        nqp::deserialize(buf_to_base64(hex_to_buf($hex)), $dsc, @strings, nqp::list(), nqp::null());
        $r := 'objects=' ~ nqp::scobjcount($dsc) ~ ' ' ~ dump(nqp::scgetobj($dsc, 0), $cls);
        CATCH { $r := 'DIED ' ~ nqp::getmessage($!) }
    }
    $r
}

sub strings_line(@sh) {
    my @p := nqp::list_s();
    my int $n := nqp::elems(@sh);
    my int $i := 0;
    while $i < $n {
        my str $s := nqp::atpos_s(@sh, $i);
        nqp::push_s(@p, nqp::isnull_s($s) ?? '<null>' !! $s);
        $i++;
    }
    $n ~ ' ' ~ nqp::join('|', @p)
}
sub strings_from(str $line) {
    my @sh := nqp::list_s();
    my int $sp := nqp::index($line, ' ');
    my int $n := +nqp::substr($line, 0, $sp);
    if $n {
        for nqp::split('|', nqp::substr($line, $sp + 1)) -> $s {
            if $s eq '<null>' { nqp::push_s(@sh, nqp::null_s()) } else { nqp::push_s(@sh, $s) }
        }
    }
    @sh
}

# $type is the array type, or for the typed kinds a routine that makes a new
# one: each typed case then carries its own STable and REPR data, so that
# serialize_repr_data, deserialize_repr_data and deserialize_stable_size run
# for every kind in every case. The four built-in types cannot be made anew;
# their STable goes into the context of the first case that serializes it
# and the later cases of that kind refer to that context by its handle. The
# reader therefore gives each context the handle the writer gave it, and
# reads the cases in the order they were written.
sub write_case(str $kind, $type, str $size) {
    my str $case := $kind ~ '.' ~ $size;
    my str $cls := cls_of($kind);
    $type := $type() if nqp::isinvokable($type);
    my $r;
    my str $hex := '';
    my @sh := nqp::list_s();
    try {
        my $a := build($type, $cls, $size);
        my $sc := nqp::createsc('VA_SERIAL_' ~ $case ~ '_IN');
        nqp::scsetobj($sc, 0, $a);
        nqp::setobjsc($a, $sc);
        $hex := buf_to_hex(nqp::serializetobuf($sc, @sh, $buf8));
        $r := $hex;
        CATCH { $r := 'DIED ' ~ nqp::getmessage($!) }
    }
    say("$case.blob: $r");
    say("$case.strings: " ~ strings_line(@sh));
    say("$case.roundtrip: " ~ ($hex eq '' ?? 'DIED no blob' !! read_case('VA_SERIAL_' ~ $case ~ '_OUT', $cls, $hex, @sh)));
}

sub write_all() {
    my @kinds := nqp::list(
        'list',   nqp::what(nqp::list()),
        'list_i', nqp::what(nqp::list_i()),
        'list_n', nqp::what(nqp::list_n()),
        'list_s', nqp::what(nqp::list_s()),
        'i8',     { arrtype(inttype(8, 0)) },
        'i16',    { arrtype(inttype(16, 0)) },
        'i32',    { arrtype(inttype(32, 0)) },
        'i64',    { arrtype(inttype(64, 0)) },
        'u8',     { arrtype(inttype(8, 1)) },
        'u16',    { arrtype(inttype(16, 1)) },
        'u32',    { arrtype(inttype(32, 1)) },
        'u64',    { arrtype(inttype(64, 1)) },
        'n32',    { arrtype(numtype(32)) },
        'n64',    { arrtype(numtype(64)) },
        'str',    { arrtype(str) },
        'obj',    { nqp::newtype(nqp::null(), 'VMArray') },
    );
    my int $i := 0;
    while $i < nqp::elems(@kinds) {
        for ('0', '3', 'shifted', '10000') -> $size {
            write_case(@kinds[$i], @kinds[$i + 1], $size);
        }
        $i := $i + 2;
    }
    # Last, because a failed deserialization is not something to run more
    # cases after: an element type of 4 bits has no storage, the empty array
    # serializes, and deserialize takes its default arm.
    write_case('u4', arrtype(inttype(4, 1)), '0');
    say('done: 1');
}

sub read_all(str $file) {
    my str $hex := '';
    my int $cases := 0;
    for nqp::split("\n", slurp($file)) -> $line {
        my int $colon := nqp::index($line, ': ');
        next if $colon < 0;
        my str $name := nqp::substr($line, 0, $colon);
        my str $value := nqp::substr($line, $colon + 2);
        if nqp::eqat($name, '.blob', nqp::chars($name) - 5) {
            $hex := $value;
        }
        elsif nqp::eqat($name, '.strings', nqp::chars($name) - 8) {
            my str $case := nqp::substr($name, 0, nqp::chars($name) - 8);
            my str $kind := nqp::substr($case, 0, nqp::index($case, '.'));
            say("$case.read: " ~ (nqp::eqat($hex, 'DIED', 0) ?? 'DIED no blob' !! read_case('VA_SERIAL_' ~ $case ~ '_IN', cls_of($kind), $hex, strings_from($value))));
            $cases++;
        }
    }
    say("done: $cases");
}

sub MAIN(*@ARGS) {
    my str $read := '';
    my int $first := 1;
    for @ARGS -> $a {
        if $first { $first := 0 }       # the program's own name
        elsif nqp::eqat($a, '--read=', 0) { $read := nqp::substr($a, 7) }
        else { nqp::die("vmarray-serial.nqp: unknown argument $a (usage: vmarray-serial.nqp [--read=FILE])") }
    }
    if $read eq '' { write_all() } else { read_all($read) }
}
