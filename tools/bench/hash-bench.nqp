#!/usr/bin/env nqp
# The nqp-level string hash benchmark: the ladder and operations of
# tools/bench/hash-bench.raku on nqp hashes (MVMHash through its REPR,
# no Raku Hash layer above it), timed with nqp::time() (nanoseconds),
# median of --runs.
#
# Per size N and run: insert N fresh keys (nqp::bindkey), lookup hit
# (nqp::existskey for N present keys), lookup miss (N keys never inserted),
# full iteration (for %h), delete N (nqp::deletekey), and for sizes T and
# T+1 (T = --threshold), or every size with --nth=all, the N-th insert
# alone into hashes of N-1. Small
# sizes are measured over a batch of (65536 div N) hashes handled in turn
# inside one timed region, so a clock read is amortised over at least 65536
# operations; the figure is nanoseconds per operation. Memory is the
# ru_maxrss delta (bytes) across the size's runs.
#
# Output: TSV lines
# engine<TAB>size<TAB>op<TAB>ns_per_op<TAB>rss_bytes<TAB>ns_min<TAB>ns_max:
# the median of the runs, then the fastest and the slowest run (the spread
# tools/bench/hash-compare.pl reports; `zig build hash-bench` emits the same
# columns).
#
# Usage: moar --libpath=<stage0> <stage0>/nqp.moarvm tools/bench/hash-bench.nqp
#            [--engine=NAME] [--sizes=N,N,...] [--runs=K] [--threshold=T]
#            [--nth=all|threshold]

my int $BATCH_OPS := 65536;

sub maxrss_bytes() {
    my $ru := nqp::list_i();
    nqp::getrusage($ru);
    nqp::atpos_i($ru, 4) * 1024    # ru_maxrss is in KB on Linux
}

sub sorted(@xs) {
    # Insertion sort, numeric (nqp::isgt_n: a bare `>` on these untyped
    # values compares them as integers); the lists are tiny (--runs
    # entries, the ladder).
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

# Nanoseconds per operation since $t0.
sub ns_per(int $t0, num $ops) { nqp::div_n(nqp::time() - $t0, $ops) }

sub to_int(str $s) { nqp::atpos(nqp::radix(10, $s, 0, 0), 0) }

# One TSV line: the median of @runs, the memory figure, the fastest and the
# slowest run.
sub emit(str $engine, int $n, str $op, @runs, int $rss) {
    my @s := sorted(@runs);
    nqp::say($engine ~ "\t" ~ $n ~ "\t" ~ $op ~ "\t" ~ nqp::sprintf('%.2f', [median(@runs)]) ~ "\t" ~ $rss
        ~ "\t" ~ nqp::sprintf('%.2f', [nqp::atpos(@s, 0)]) ~ "\t" ~ nqp::sprintf('%.2f', [nqp::atpos(@s, nqp::elems(@s) - 1)]));
}

# The timed phases, one sub each, so spesh specialises (and OSRs) every
# timed loop on its own: as statements of one big MAIN, the specialisation
# of a loop depended on what ran before it (with the C engine, nqp::deletekey
# timed at 30 ns at every size when the ladder went up to 16384 and at 15 ns
# when it stopped at 4096). Each pushes its ns per operation onto @out.
sub time_insert(@out, @tables, @keys, int $reps, int $n, num $ops) {
    my int $t0 := nqp::time();
    my int $r := 0;
    while $r < $reps {
        my %h := nqp::atpos(@tables, $r);
        my int $j := 0;
        while $j < $n { nqp::bindkey(%h, nqp::atpos(@keys, $j), 1); $j := $j + 1 }
        $r := $r + 1;
    }
    nqp::push(@out, ns_per($t0, $ops));
}

# Returns how many of the keys were found.
sub time_hit(@out, @tables, @keys, int $reps, int $n, num $ops) {
    my int $hits := 0;
    my int $t0 := nqp::time();
    my int $r := 0;
    while $r < $reps {
        my %h := nqp::atpos(@tables, $r);
        my int $j := 0;
        while $j < $n { $hits := $hits + 1 if nqp::existskey(%h, nqp::atpos(@keys, $j)); $j := $j + 1 }
        $r := $r + 1;
    }
    nqp::push(@out, ns_per($t0, $ops));
    $hits
}

# Returns how many of the keys were absent.
sub time_miss(@out, @tables, @keys, int $reps, int $n, num $ops) {
    my int $nohits := 0;
    my int $t0 := nqp::time();
    my int $r := 0;
    while $r < $reps {
        my %h := nqp::atpos(@tables, $r);
        my int $j := 0;
        while $j < $n { $nohits := $nohits + 1 unless nqp::existskey(%h, nqp::atpos(@keys, $j)); $j := $j + 1 }
        $r := $r + 1;
    }
    nqp::push(@out, ns_per($t0, $ops));
    $nohits
}

# Returns how many entries were iterated.
sub time_iterate(@out, @tables, int $reps, num $ops) {
    my int $seen := 0;
    my int $t0 := nqp::time();
    my int $r := 0;
    while $r < $reps {
        my %h := nqp::atpos(@tables, $r);
        for %h { $seen := $seen + 1 }
        $r := $r + 1;
    }
    nqp::push(@out, ns_per($t0, $ops));
    $seen
}

sub time_delete(@out, @tables, @keys, int $reps, int $n, num $ops) {
    my int $t0 := nqp::time();
    my int $r := 0;
    while $r < $reps {
        my %h := nqp::atpos(@tables, $r);
        my int $j := 0;
        while $j < $n { nqp::deletekey(%h, nqp::atpos(@keys, $j)); $j := $j + 1 }
        $r := $r + 1;
    }
    nqp::push(@out, ns_per($t0, $ops));
}

# The N-th insert: one bind of $key into each table (ns per table).
sub time_nth(@out, @tables, str $key, int $reps, num $reps_n) {
    my int $t0 := nqp::time();
    my int $r := 0;
    while $r < $reps { nqp::bindkey(nqp::atpos(@tables, $r), $key, 1); $r := $r + 1 }
    nqp::push(@out, ns_per($t0, $reps_n));
}

sub MAIN(*@ARGS) {
    my str $engine := 'nqp';
    my str $sizes := '';
    my int $runs := 3;
    my int $threshold := 64;
    my int $nth_all := 0;
    for @ARGS -> $a {
        if nqp::eqat($a, '--engine=', 0) { $engine := nqp::substr($a, 9) }
        elsif nqp::eqat($a, '--sizes=', 0) { $sizes := nqp::substr($a, 8) }
        elsif nqp::eqat($a, '--runs=', 0) { $runs := to_int(nqp::substr($a, 7)) }
        elsif nqp::eqat($a, '--threshold=', 0) { $threshold := to_int(nqp::substr($a, 12)) }
        elsif $a eq '--nth=all' { $nth_all := 1 }
        elsif $a eq '--nth=threshold' { $nth_all := 0 }
        elsif nqp::eqat($a, '--', 0) { nqp::die("hash-bench.nqp: unknown option $a") }
    }
    nqp::die("--runs must be at least 1") if $runs < 1;

    my @sizes;
    if $sizes eq '' {
        for (4, 16, 32, 128, 256, 1024, 16384, 65536, 1048576, $threshold - 1, $threshold, $threshold + 1) {
            nqp::push(@sizes, $_) if $_ > 0;
        }
    }
    else {
        for nqp::split(',', $sizes) { nqp::push(@sizes, to_int($_)) if nqp::chars($_) }
    }
    # Numeric sort, duplicates collapsed.
    my %seen;
    my @measured;
    for @sizes { unless nqp::existskey(%seen, ~$_) { %seen{~$_} := 1; nqp::push(@measured, $_) } }
    @measured := sorted(@measured);
    return 0 unless nqp::elems(@measured);

    my int $max := nqp::atpos(@measured, nqp::elems(@measured) - 1);
    my @present;
    my @miss;
    my int $i := 0;
    while $i < $max {
        nqp::push(@present, "k" ~ $i);
        nqp::push(@miss, "m" ~ $i);
        $i := $i + 1;
    }

    for @measured -> int $n {
        my int $reps := nqp::div_i($BATCH_OPS, $n);
        $reps := 1 if $reps < 1;
        my num $reps_n := $reps;
        my num $ops := $n * $reps;
        my @insert; my @hit; my @missed; my @iterate; my @delete;
        my int $rss_before := maxrss_bytes();
        my int $run := 0;
        while $run < $runs {
            my @tables;
            my int $r := 0;
            while $r < $reps { nqp::push(@tables, nqp::hash()); $r := $r + 1 }
            time_insert(@insert, @tables, @present, $reps, $n, $ops);
            my int $hits := time_hit(@hit, @tables, @present, $reps, $n, $ops);
            my int $nohits := time_miss(@missed, @tables, @miss, $reps, $n, $ops);
            my int $seen := time_iterate(@iterate, @tables, $reps, $ops);
            time_delete(@delete, @tables, @present, $reps, $n, $ops);

            my int $left := 0;
            for @tables { $left := $left + 1 if nqp::elems($_) }
            nqp::die("size $n: $hits hits, $nohits misses, $seen iterated, $left hashes not empty after delete (expected $ops, $ops, $ops, 0)")
                unless $hits == $ops && $nohits == $ops && $seen == $ops && $left == 0;
            $run := $run + 1;
        }
        my int $rss := maxrss_bytes() - $rss_before;
        emit($engine, $n, 'insert', @insert, $rss);
        emit($engine, $n, 'lookup_hit', @hit, $rss);
        emit($engine, $n, 'lookup_miss', @missed, $rss);
        emit($engine, $n, 'delete', @delete, $rss);
        emit($engine, $n, 'iterate', @iterate, $rss);
        if $nth_all || $n == $threshold || $n == $threshold + 1 {
            # The N-th insert alone: hashes of N-1 keys, then one insert each.
            my @nth;
            my str $last := nqp::atpos(@present, $n - 1);
            $run := 0;
            while $run < $runs {
                my @tables;
                my int $r := 0;
                while $r < $reps {
                    my %h := nqp::hash();
                    my int $j := 0;
                    while $j < $n - 1 { nqp::bindkey(%h, nqp::atpos(@present, $j), 1); $j := $j + 1 }
                    nqp::push(@tables, %h);
                    $r := $r + 1;
                }
                time_nth(@nth, @tables, $last, $reps, $reps_n);
                for @tables { nqp::die("size $n: a hash has " ~ nqp::elems($_) ~ " keys after the N-th insert") unless nqp::elems($_) == $n }
                $run := $run + 1;
            }
            emit($engine, $n, 'insert_nth', @nth, $rss);
        }
    }
}
