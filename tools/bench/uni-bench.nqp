#!/usr/bin/env nqp
# The nqp-level unicode lookup benchmark: the four tables behind the unicode
# ops (u1 property names, u2 named sequences, u3 codepoint names, u4 property
# values; MVMUniHashTable), timed through the ops that reach them with
# nqp::time() (nanoseconds), median of --runs. Output is the 7-column TSV of
# tools/bench/hash-bench.nqp: engine, size (the number of distinct keys of
# the cell), op, ns per op, rss bytes, ns min, ns max.
#
# Cells (each one sub, so spesh specialises each on its own; the ops are
# :pure, so each iteration passes a different key from a list):
#   cpbyname_hit          nqp::codepointfromname of real names
#   cpbyname_miss         the same names with " ZZZ" appended (-1 expected)
#   cpbyname_miss_prefix  names the table lacks but the prefix fallbacks of
#                         MVM_unicode_lookup_by_name resolve, all distinct:
#                         CJK COMPATIBILITY IDEOGRAPH-<hex> for 0xF900..0xFAFF,
#                         then CJK UNIFIED IDEOGRAPH-<hex> from 0x4E00 (21,504
#                         keys at most: --sample is clamped to that)
#   propcode_hit          nqp::unipropcode of the longest name of each property (its long form)
#   propcode_alias        ... of their aliases
#   propcode_miss         ... of every name with "_X" appended (0 expected)
#   pvalcode_hit          nqp::unipvalcode of property value names
#   pvalcode_miss         ... with "_X" appended (0 expected)
#   strfromname_seq       nqp::strfromname of named sequence names
# Every _hit cell dies on any miss and every _miss cell on any hit.
#
# Property, alias, value and sequence names come from the key file
# tools/bench/uni-bench-keys.tsv (tools/bench/uni-bench-keys.pl). Codepoint
# names are harvested with nqp::getuniname for 0..0x2FFFF, skipping empty
# names, placeholders (starting with `<`) and algorithmic names (a trailing
# -HEX, resolved by prefix, not by the table), then --sample of them are
# taken after a shuffle by an LCG seeded with 0x5eed. Each cell is walked
# repeatedly (a calibration doubling sizes the repeat count) so a timed region
# lasts 50 to 100 ms (so the lookups dominate the process's startup in the
# hash statistics).
#
# Usage: <prefix>/bin/nqp-m tools/bench/uni-bench.nqp
#            [--engine=NAME] [--runs=K] [--ops=a,b] [--sample=N] [--keys=PATH]

sub maxrss_bytes() {
    my $ru := nqp::list_i();
    nqp::getrusage($ru);
    nqp::atpos_i($ru, 4) * 1024    # ru_maxrss is in KB on Linux
}

sub sorted(@xs) {
    my @s;
    for @xs { nqp::push(@s, $_) }
    my int $n := nqp::elems(@s);
    my int $i := 1;
    while $i < $n {
        my $v := nqp::atpos(@s, $i);
        my int $j := $i - 1;
        while $j >= 0 && nqp::isgt_n(nqp::atpos(@s, $j), $v) {
            nqp::bindpos(@s, $j + 1, nqp::atpos(@s, $j));
            $j := $j - 1;
        }
        nqp::bindpos(@s, $j + 1, $v);
        $i := $i + 1;
    }
    @s
}

sub median(@xs) {
    my @s := sorted(@xs);
    nqp::atpos(@s, nqp::div_i(nqp::elems(@s), 2))
}

sub ns_per(int $t0, int $ops) { my num $o := $ops; nqp::div_n(nqp::time() - $t0, $o) }

sub to_int(str $s) { nqp::atpos(nqp::radix(10, $s, 0, 0), 0) }

sub emit(str $engine, int $n, str $op, @runs, int $rss) {
    my @s := sorted(@runs);
    nqp::say($engine ~ "\t" ~ $n ~ "\t" ~ $op ~ "\t" ~ nqp::sprintf('%.2f', [median(@runs)]) ~ "\t" ~ $rss
        ~ "\t" ~ nqp::sprintf('%.2f', [nqp::atpos(@s, 0)]) ~ "\t" ~ nqp::sprintf('%.2f', [nqp::atpos(@s, nqp::elems(@s) - 1)]));
}

sub hex(int $n) { nqp::sprintf('%X', [$n]) }

# The timed cells. Each walks @keys $reps times, pushes ns per lookup onto
# @out and returns how many results were wrong (a miss in a _hit cell, a hit
# in a _miss cell).
sub time_cp_hit(@out, @keys, int $reps) {
    my int $n := nqp::elems(@keys);
    my int $bad := 0;
    my int $t0 := nqp::time();
    my int $r := 0;
    while $r < $reps {
        my int $j := 0;
        while $j < $n { $bad := $bad + 1 if nqp::codepointfromname(nqp::atpos(@keys, $j)) < 0; $j := $j + 1 }
        $r := $r + 1;
    }
    nqp::push(@out, ns_per($t0, $n * $reps));
    $bad
}

sub time_cp_miss(@out, @keys, int $reps) {
    my int $n := nqp::elems(@keys);
    my int $bad := 0;
    my int $t0 := nqp::time();
    my int $r := 0;
    while $r < $reps {
        my int $j := 0;
        while $j < $n { $bad := $bad + 1 if nqp::codepointfromname(nqp::atpos(@keys, $j)) >= 0; $j := $j + 1 }
        $r := $r + 1;
    }
    nqp::push(@out, ns_per($t0, $n * $reps));
    $bad
}

# Prefix names resolve to the codepoint in @expect.
sub time_cp_prefix(@out, @keys, @expect, int $reps) {
    my int $n := nqp::elems(@keys);
    my int $bad := 0;
    my int $t0 := nqp::time();
    my int $r := 0;
    while $r < $reps {
        my int $j := 0;
        while $j < $n { $bad := $bad + 1 if nqp::codepointfromname(nqp::atpos(@keys, $j)) != nqp::atpos(@expect, $j); $j := $j + 1 }
        $r := $r + 1;
    }
    nqp::push(@out, ns_per($t0, $n * $reps));
    $bad
}

# Property names resolve to the code in @expect (hit, alias).
sub time_prop_hit(@out, @keys, @expect, int $reps) {
    my int $n := nqp::elems(@keys);
    my int $bad := 0;
    my int $t0 := nqp::time();
    my int $r := 0;
    while $r < $reps {
        my int $j := 0;
        while $j < $n { $bad := $bad + 1 if nqp::unipropcode(nqp::atpos(@keys, $j)) != nqp::atpos(@expect, $j); $j := $j + 1 }
        $r := $r + 1;
    }
    nqp::push(@out, ns_per($t0, $n * $reps));
    $bad
}

sub time_prop_miss(@out, @keys, int $reps) {
    my int $n := nqp::elems(@keys);
    my int $bad := 0;
    my int $t0 := nqp::time();
    my int $r := 0;
    while $r < $reps {
        my int $j := 0;
        while $j < $n { $bad := $bad + 1 if nqp::unipropcode(nqp::atpos(@keys, $j)) != 0; $j := $j + 1 }
        $r := $r + 1;
    }
    nqp::push(@out, ns_per($t0, $n * $reps));
    $bad
}

sub time_pval_hit(@out, @codes, @keys, int $reps) {
    my int $n := nqp::elems(@keys);
    my int $bad := 0;
    my int $t0 := nqp::time();
    my int $r := 0;
    while $r < $reps {
        my int $j := 0;
        while $j < $n { $bad := $bad + 1 if nqp::unipvalcode(nqp::atpos(@codes, $j), nqp::atpos(@keys, $j)) == 0; $j := $j + 1 }
        $r := $r + 1;
    }
    nqp::push(@out, ns_per($t0, $n * $reps));
    $bad
}

sub time_pval_miss(@out, @codes, @keys, int $reps) {
    my int $n := nqp::elems(@keys);
    my int $bad := 0;
    my int $t0 := nqp::time();
    my int $r := 0;
    while $r < $reps {
        my int $j := 0;
        while $j < $n { $bad := $bad + 1 if nqp::unipvalcode(nqp::atpos(@codes, $j), nqp::atpos(@keys, $j)) != 0; $j := $j + 1 }
        $r := $r + 1;
    }
    nqp::push(@out, ns_per($t0, $n * $reps));
    $bad
}

sub time_seq(@out, @keys, int $reps) {
    my int $n := nqp::elems(@keys);
    my int $bad := 0;
    my int $t0 := nqp::time();
    my int $r := 0;
    while $r < $reps {
        my int $j := 0;
        while $j < $n { $bad := $bad + 1 if nqp::chars(nqp::strfromname(nqp::atpos(@keys, $j))) == 0; $j := $j + 1 }
        $r := $r + 1;
    }
    nqp::push(@out, ns_per($t0, $n * $reps));
    $bad
}

# Run one cell: $cell names the sub. Returns the wrong-answer count.
sub run_cell(str $cell, @out, @keys, @codes, @expect, int $reps) {
    if $cell eq 'cpbyname_hit' { time_cp_hit(@out, @keys, $reps) }
    elsif $cell eq 'cpbyname_miss' { time_cp_miss(@out, @keys, $reps) }
    elsif $cell eq 'cpbyname_miss_prefix' { time_cp_prefix(@out, @keys, @expect, $reps) }
    elsif $cell eq 'propcode_hit' || $cell eq 'propcode_alias' { time_prop_hit(@out, @keys, @expect, $reps) }
    elsif $cell eq 'propcode_miss' { time_prop_miss(@out, @keys, $reps) }
    elsif $cell eq 'pvalcode_hit' { time_pval_hit(@out, @codes, @keys, $reps) }
    elsif $cell eq 'pvalcode_miss' { time_pval_miss(@out, @codes, @keys, $reps) }
    else { time_seq(@out, @keys, $reps) }
}

# The key file: rows of kind, name[, value]. Returns a hash of kind to a list
# of [name, value] pairs; dies on a malformed row.
sub read_keys(str $path) {
    my str $text := slurp($path);
    my %rows;
    my int $lineno := 0;
    for nqp::split("\n", $text) -> $line {
        $lineno := $lineno + 1;
        next unless nqp::chars($line);
        my @f := nqp::split("\t", $line);
        my str $kind := nqp::atpos(@f, 0);
        my int $want := ($kind eq 'seq') ?? 2 !! 3;
        nqp::die("uni-bench.nqp: malformed key row $lineno in $path: $line")
            unless ($kind eq 'prop' || $kind eq 'alias' || $kind eq 'pval' || $kind eq 'seq')
                && nqp::elems(@f) == $want && nqp::chars(nqp::atpos(@f, 1));
        %rows{$kind} := nqp::list() unless nqp::existskey(%rows, $kind);
        nqp::push(%rows{$kind}, @f);
    }
    %rows
}

# Real codepoint names with a table entry, shuffled by the seeded LCG.
sub harvest_names(int $sample) {
    my @names;
    my int $cp := 0;
    while $cp < 0x30000 {
        my str $nm := nqp::getuniname($cp);
        my int $len := nqp::chars($nm);
        if $len && !nqp::eqat($nm, '<', 0) {
            # Algorithmic names end in -HEX (4 to 6 digits): not table entries.
            my int $dash := nqp::rindex($nm, '-');
            my int $tail := $len - $dash - 1;
            my int $algo := 0;
            if $dash >= 0 && $tail >= 4 && $tail <= 6 {
                $algo := 1;
                my int $k := $dash + 1;
                while $k < $len {
                    my int $ch := nqp::ord($nm, $k);
                    $algo := 0 unless ($ch >= 48 && $ch <= 57) || ($ch >= 65 && $ch <= 70);
                    $k := $k + 1;
                }
            }
            nqp::push(@names, $nm) unless $algo;
        }
        $cp := $cp + 1;
    }
    my int $x := 0x5eed;
    my int $i := nqp::elems(@names) - 1;
    while $i > 0 {
        $x := nqp::bitand_i($x * 1103515245 + 12345, 0x7fffffff);
        my int $j := $x % ($i + 1);
        my $t := nqp::atpos(@names, $i);
        nqp::bindpos(@names, $i, nqp::atpos(@names, $j));
        nqp::bindpos(@names, $j, $t);
        $i := $i - 1;
    }
    my @out;
    $i := 0;
    while $i < $sample && $i < nqp::elems(@names) { nqp::push(@out, nqp::atpos(@names, $i)); $i := $i + 1 }
    @out
}

sub suffixed(@keys, str $suffix) {
    my @out;
    for @keys { nqp::push(@out, $_ ~ $suffix) }
    @out
}

sub MAIN(*@ARGS) {
    my str $engine := 'zig';
    my int $runs := 3;
    my int $sample := 4096;
    my str $ops := '';
    my str $keys_path := 'tools/bench/uni-bench-keys.tsv';
    for @ARGS -> $a {
        if nqp::eqat($a, '--engine=', 0) { $engine := nqp::substr($a, 9) }
        elsif nqp::eqat($a, '--runs=', 0) { $runs := to_int(nqp::substr($a, 7)) }
        elsif nqp::eqat($a, '--sample=', 0) { $sample := to_int(nqp::substr($a, 9)) }
        elsif nqp::eqat($a, '--ops=', 0) { $ops := nqp::substr($a, 6) }
        elsif nqp::eqat($a, '--keys=', 0) { $keys_path := nqp::substr($a, 7) }
        elsif nqp::eqat($a, '--', 0) { nqp::die("uni-bench.nqp: unknown option $a") }
    }
    nqp::die("--runs must be at least 1") if $runs < 1;
    nqp::die("--sample must be at least 1") if $sample < 1;

    my @all := nqp::split(',', 'cpbyname_hit,cpbyname_miss,cpbyname_miss_prefix,propcode_hit,propcode_alias,propcode_miss,pvalcode_hit,pvalcode_miss,strfromname_seq');
    my %known;
    for @all { %known{$_} := 1 }
    my @cells;
    if $ops eq '' { @cells := @all }
    else {
        for nqp::split(',', $ops) -> $o {
            next unless nqp::chars($o);
            nqp::die("uni-bench.nqp: unknown op $o") unless nqp::existskey(%known, $o);
            nqp::push(@cells, $o);
        }
    }

    my %rows := read_keys($keys_path);
    my %want;
    for @cells { %want{$_} := 1 }
    my int $need_names := %want<cpbyname_hit> || %want<cpbyname_miss>;
    my @names := $need_names ?? harvest_names($sample) !! nqp::list();

    my int $rss_before := maxrss_bytes();
    for @cells -> $cell {
        my @keys; my @codes; my @expect;
        if $cell eq 'cpbyname_hit' { @keys := @names }
        elsif $cell eq 'cpbyname_miss' { @keys := suffixed(@names, ' ZZZ') }
        elsif $cell eq 'cpbyname_miss_prefix' {
            my int $i := 0;
            my int $count := $sample < 21504 ?? $sample !! 21504;
            while $i < $count {
                my int $cp := $i < 512 ?? 0xF900 + $i !! 0x4E00 + $i - 512;
                nqp::push(@keys, ($i < 512 ?? 'CJK COMPATIBILITY IDEOGRAPH-' !! 'CJK UNIFIED IDEOGRAPH-') ~ hex($cp));
                nqp::push(@expect, $cp);
                $i := $i + 1;
            }
        }
        elsif $cell eq 'propcode_hit' || $cell eq 'propcode_alias' {
            for %rows{$cell eq 'propcode_hit' ?? 'prop' !! 'alias'} -> @r { nqp::push(@keys, nqp::atpos(@r, 1)); nqp::push(@expect, to_int(nqp::atpos(@r, 2))) }
        }
        elsif $cell eq 'propcode_miss' {
            for %rows<prop> -> @r { nqp::push(@keys, nqp::atpos(@r, 1) ~ '_X') }
            for %rows<alias> -> @r { nqp::push(@keys, nqp::atpos(@r, 1) ~ '_X') }
        }
        elsif $cell eq 'pvalcode_hit' || $cell eq 'pvalcode_miss' {
            for %rows<pval> -> @r {
                nqp::push(@codes, to_int(nqp::atpos(@r, 1)));
                nqp::push(@keys, nqp::atpos(@r, 2) ~ ($cell eq 'pvalcode_miss' ?? '_X' !! ''));
            }
        }
        else { for %rows<seq> -> @r { nqp::push(@keys, nqp::atpos(@r, 1)) } }
        nqp::die("uni-bench.nqp: no keys for $cell (key file $keys_path lacks its rows)") unless nqp::elems(@keys);

        # Calibration (which also verifies and warms up): double the repeat
        # count until one timed region lasts 50 ms (so 50 to 100 ms).
        my int $reps := 1;
        my int $bad := 0;
        my num $elapsed := 0;
        while 1 {
            my @probe;
            $bad := $bad + run_cell($cell, @probe, @keys, @codes, @expect, $reps);
            $elapsed := nqp::atpos(@probe, 0) * nqp::elems(@keys) * $reps;
            last if $elapsed >= 50000000;
            $reps := $reps * 2;
        }
        my @times;
        my int $run := 0;
        while $run < $runs {
            $bad := $bad + run_cell($cell, @times, @keys, @codes, @expect, $reps);
            $run := $run + 1;
        }
        nqp::die("uni-bench.nqp: $cell: $bad wrong answers in " ~ nqp::elems(@keys) ~ " keys") if $bad;
        emit($engine, nqp::elems(@keys), $cell, @times, maxrss_bytes() - $rss_before);
    }
}
