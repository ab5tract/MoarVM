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
# alone into hashes of N-1. Four more rows per size, all per entry:
# overwrite (bind each of the N present keys again, with a new value, on the
# filled hash), clone (nqp::clone of the filled hash, the clones kept alive
# until the timing ends), iterate_delete (one `for` over the filled hash
# deleting the current key with nqp::deletekey, MVMIter's delete-at-current
# path; the hashes are refilled after delete for it) and bulk_load (insert N
# into fresh hashes, then nqp::hashseal each). Small
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
# Layout strategies (the hash layout bake-off, tools/bench/hash-bakeoff.sh):
# --strategy=N calls nqp::hashstrategy(%h, N, HINT) on every hash the
# timed phases use, right after its nqp::hash() (default 0, the default
# ladder: the op is still called, so strategy 0 pays the same per-hash call
# as the others). --hint=0 (the default) passes size hint 0, so every hash
# grows through its tiers as it fills, as the ladder records' hashes did:
# insert, insert_nth at the threshold and the resize sizes (49, 97) time
# that growth. --hint=size passes the size N as the hint, so every hash is
# built presized and no timed row grows a table (the presized variant; the
# engine column then defaults to zig-s<N>-presized). --seal calls
# nqp::hashseal on every hash after each fill and before the lookup,
# iterate and delete phases; with --seal the insert and insert_nth rows are
# not emitted (they would time the staging table, not the sealed layout).
# The engine column defaults to zig-s<N>.
#
# The two ops are not known to the JIT, so a frame calling them is never
# JIT-compiled: they are called in MAIN, outside the timed subs, except in
# time_bulk_load, which times insert-then-seal and so runs interpreted for
# every strategy alike (a sub of its own, so the others stay JIT-compiled).
# The ops need an nqp that maps them (nqp branch zig-hash-strategies, e.g.
# <prefix>/bin/nqp-m); nqp's stage0 does not until it is rebuilt.
#
# Usage: <prefix>/bin/nqp-m tools/bench/hash-bench.nqp
#            [--engine=NAME] [--sizes=N,N,...] [--runs=K] [--threshold=T]
#            [--nth=all|threshold] [--strategy=N] [--hint=0|size] [--seal]

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

# Bind each present key again, with a new value, on the filled hashes.
sub time_overwrite(@out, @tables, @keys, int $reps, int $n, num $ops) {
    my int $t0 := nqp::time();
    my int $r := 0;
    while $r < $reps {
        my %h := nqp::atpos(@tables, $r);
        my int $j := 0;
        while $j < $n { nqp::bindkey(%h, nqp::atpos(@keys, $j), 2); $j := $j + 1 }
        $r := $r + 1;
    }
    nqp::push(@out, ns_per($t0, $ops));
}

# nqp::clone of each filled hash; the clones are held in a list allocated
# before the clock starts, so they all stay alive until the timing ends.
# Returns the clones.
sub time_clone(@out, @tables, int $reps, num $ops) {
    my @clones := nqp::list();
    nqp::setelems(@clones, $reps);
    my int $t0 := nqp::time();
    my int $r := 0;
    while $r < $reps {
        nqp::bindpos(@clones, $r, nqp::clone(nqp::atpos(@tables, $r)));
        $r := $r + 1;
    }
    nqp::push(@out, ns_per($t0, $ops));
    @clones
}

# One `for` over each filled hash deleting the current key inside the loop
# (MVMIter's delete-at-current path). Returns how many keys were deleted.
sub time_iterate_delete(@out, @tables, int $reps, num $ops) {
    my int $deleted := 0;
    my int $t0 := nqp::time();
    my int $r := 0;
    while $r < $reps {
        my %h := nqp::atpos(@tables, $r);
        for %h { nqp::deletekey(%h, nqp::iterkey_s($_)); $deleted := $deleted + 1 }
        $r := $r + 1;
    }
    nqp::push(@out, ns_per($t0, $ops));
    $deleted
}

# Insert N into each fresh hash, then seal it. nqp::hashseal is a no-op
# without a sealable strategy, so the row is comparable across strategies;
# the op is not known to the JIT, so this sub runs interpreted for every
# strategy alike, and is kept apart from the other timed subs for that.
sub time_bulk_load(@out, @tables, @keys, int $reps, int $n, num $ops) {
    my int $t0 := nqp::time();
    my int $r := 0;
    while $r < $reps {
        my %h := nqp::atpos(@tables, $r);
        my int $j := 0;
        while $j < $n { nqp::bindkey(%h, nqp::atpos(@keys, $j), 1); $j := $j + 1 }
        nqp::hashseal(%h);
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
    my str $engine := '';
    my int $strategy := 0;
    my int $presized := 0;
    my int $seal := 0;
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
        elsif nqp::eqat($a, '--strategy=', 0) { $strategy := to_int(nqp::substr($a, 11)) }
        elsif $a eq '--seal' { $seal := 1 }
        elsif $a eq '--hint=0' { $presized := 0 }
        elsif $a eq '--hint=size' { $presized := 1 }
        elsif nqp::eqat($a, '--', 0) { nqp::die("hash-bench.nqp: unknown option $a") }
    }
    nqp::die("--runs must be at least 1") if $runs < 1;
    $engine := 'zig-s' ~ $strategy ~ ($presized ?? '-presized' !! '') if $engine eq '';

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
        my int $hint := $presized ?? $n !! 0;
        my int $reps := nqp::div_i($BATCH_OPS, $n);
        $reps := 1 if $reps < 1;
        my num $reps_n := $reps;
        my num $ops := $n * $reps;
        my @insert; my @hit; my @missed; my @iterate; my @delete;
        my @overwrite; my @clone; my @iterate_delete; my @bulk_load;
        my int $rss_before := maxrss_bytes();
        my int $run := 0;
        while $run < $runs {
            my @tables;
            my int $r := 0;
            while $r < $reps { nqp::push(@tables, nqp::hashstrategy(nqp::hash(), $strategy, $hint)); $r := $r + 1 }
            time_insert(@insert, @tables, @present, $reps, $n, $ops);
            if $seal { for @tables { nqp::hashseal($_) } }
            my int $hits := time_hit(@hit, @tables, @present, $reps, $n, $ops);
            my int $nohits := time_miss(@missed, @tables, @miss, $reps, $n, $ops);
            my int $seen := time_iterate(@iterate, @tables, $reps, $ops);
            time_overwrite(@overwrite, @tables, @present, $reps, $n, $ops);
            my @clones := time_clone(@clone, @tables, $reps, $ops);
            my int $cloned := 0;
            for @clones { $cloned := $cloned + nqp::elems($_) }
            @clones := nqp::list();
            my int $rebound := 0;
            for @tables { $rebound := $rebound + 1 if nqp::atkey($_, nqp::atpos(@present, $n - 1)) == 2 }
            time_delete(@delete, @tables, @present, $reps, $n, $ops);

            my int $left := 0;
            for @tables { $left := $left + 1 if nqp::elems($_) }
            nqp::die("size $n: $hits hits, $nohits misses, $seen iterated, $cloned cloned entries, $rebound hashes overwritten, $left hashes not empty after delete (expected $ops, $ops, $ops, $ops, $reps, 0)")
                unless $hits == $ops && $nohits == $ops && $seen == $ops && $cloned == $ops && $rebound == $reps && $left == 0;

            # Refill the emptied hashes (untimed) for iterate_delete.
            for @tables -> %h {
                my int $j := 0;
                while $j < $n { nqp::bindkey(%h, nqp::atpos(@present, $j), 1); $j := $j + 1 }
                nqp::hashseal(%h) if $seal;
            }
            my int $deleted := time_iterate_delete(@iterate_delete, @tables, $reps, $ops);
            $left := 0;
            for @tables { $left := $left + 1 if nqp::elems($_) }
            nqp::die("size $n: iterate_delete deleted $deleted, $left hashes not empty (expected $ops, 0)")
                unless $deleted == $ops && $left == 0;

            # bulk_load: fresh hashes, insert N then seal.
            @tables := nqp::list();
            $r := 0;
            while $r < $reps { nqp::push(@tables, nqp::hashstrategy(nqp::hash(), $strategy, $hint)); $r := $r + 1 }
            time_bulk_load(@bulk_load, @tables, @present, $reps, $n, $ops);
            for @tables { nqp::die("size $n: a hash has " ~ nqp::elems($_) ~ " keys after bulk_load") unless nqp::elems($_) == $n }
            $run := $run + 1;
        }
        my int $rss := maxrss_bytes() - $rss_before;
        # With --seal the insert rows would time the staging table a sealing
        # strategy fills before it seals, not its sealed layout: not emitted.
        emit($engine, $n, 'insert', @insert, $rss) unless $seal;
        emit($engine, $n, 'lookup_hit', @hit, $rss);
        emit($engine, $n, 'lookup_miss', @missed, $rss);
        emit($engine, $n, 'delete', @delete, $rss);
        emit($engine, $n, 'iterate', @iterate, $rss);
        emit($engine, $n, 'bulk_load', @bulk_load, $rss);
        emit($engine, $n, 'overwrite', @overwrite, $rss);
        emit($engine, $n, 'clone', @clone, $rss);
        emit($engine, $n, 'iterate_delete', @iterate_delete, $rss);
        # insert_nth also times an insert into the staging table: not with --seal.
        if !$seal && ($nth_all || $n == $threshold || $n == $threshold + 1) {
            # The N-th insert alone: hashes of N-1 keys, then one insert each.
            my @nth;
            my str $last := nqp::atpos(@present, $n - 1);
            $run := 0;
            while $run < $runs {
                my @tables;
                my int $r := 0;
                while $r < $reps {
                    my %h := nqp::hashstrategy(nqp::hash(), $strategy, $hint);
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
