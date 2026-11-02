#!/usr/bin/env raku
# The Raku-level string hash benchmark of spec §10: the microbenchmark's
# size ladder and operations on a Hash, timed with `now`, median of --runs.
#
# Per size N and run: insert N fresh keys (%h{$k} = $v), lookup hit
# (%h{$k}:exists for N present keys), lookup miss (N keys never inserted),
# full iteration (for %h.kv), delete N (%h{$k}:delete). Small sizes are
# measured over a batch of (65536 div N) hashes handled in turn inside one
# timed region, as the microbenchmark does, so a clock read is amortised
# over at least 65536 operations; the figure is nanoseconds per operation.
# Memory is the ru_maxrss delta (bytes, from nqp::getrusage, a high-water
# mark, so later rows often show 0) across the size's runs.
#
# Output: TSV lines engine<TAB>size<TAB>op<TAB>ns_per_op<TAB>alloc_bytes,
# the microbenchmark's columns; --engine= fills the first.
#
# Usage: raku tools/bench/hash-bench.raku [--engine=NAME] [--sizes=N,N,...]
#            [--runs=K] [--threshold=T] [--max-size=N]
use nqp;

my constant BATCH-OPS = 65536;

# The spec's ladder for a Small tier of $t entries: fixed rungs plus T-1, T,
# T+1, sorted, duplicates collapsed (bench.zig's `ladder`).
sub ladder(Int $t) {
    (4, 16, 32, 128, 256, 1024, 16384, 65536, 1048576, $t - 1, $t, $t + 1).grep(* > 0).unique.sort
}

sub maxrss-bytes() {
    my $ru := nqp::list_i();
    nqp::getrusage($ru);
    nqp::atpos_i($ru, 4) * 1024    # ru_maxrss is in KB on Linux
}

sub median(@xs) { @xs.sort[@xs.elems div 2] }

sub MAIN(Str :$engine = 'raku', Str :$sizes, Int :$runs = 3, Int :$threshold = 64, Int :$max-size = 1048576) {
    die "--runs must be at least 1" if $runs < 1;
    my @sizes = $sizes.defined ?? $sizes.split(',').grep(*.chars).map(*.Int) !! ladder($threshold);
    my @measured = @sizes.grep({ $_ <= $max-size });
    for @sizes.grep({ $_ > $max-size }) { note "hash-bench.raku: skipping size $_ above --max-size=$max-size" }
    return unless @measured;

    my $max = @measured.max;
    my @present = (^$max).map({ "k$_" });
    my @miss    = (^$max).map({ "m$_" });

    for @measured -> $n {
        my $reps = max(1, BATCH-OPS div $n);
        my @keys = @present[^$n];
        my @misses = @miss[^$n];
        my $ops = $n * $reps;
        my (@insert, @hit, @missed, @iterate, @delete);
        my $rss-before = maxrss-bytes();
        for ^$runs {
            my @tables = Hash.new xx $reps;

            my $t0 = now;
            for @tables -> %h { for @keys -> $k { %h{$k} = 1 } }
            @insert.push: (now - $t0) * 1e9 / $ops;

            my int $hits = 0;
            $t0 = now;
            for @tables -> %h { for @keys -> $k { $hits++ if %h{$k}:exists } }
            @hit.push: (now - $t0) * 1e9 / $ops;

            my int $nohits = 0;
            $t0 = now;
            for @tables -> %h { for @misses -> $k { $nohits++ unless %h{$k}:exists } }
            @missed.push: (now - $t0) * 1e9 / $ops;

            my int $seen = 0;
            $t0 = now;
            for @tables -> %h { for %h.kv -> $k, $v { $seen++ } }
            @iterate.push: (now - $t0) * 1e9 / $ops;

            $t0 = now;
            for @tables -> %h { for @keys -> $k { %h{$k}:delete } }
            @delete.push: (now - $t0) * 1e9 / $ops;

            my $left = @tables.grep(*.elems).elems;
            die "size $n: $hits hits, $nohits misses, $seen iterated, $left hashes not empty after delete (expected $ops, $ops, $ops, 0)"
                unless $hits == $ops && $nohits == $ops && $seen == $ops && $left == 0;
        }
        my $rss = maxrss-bytes() - $rss-before;
        for (insert => @insert, lookup_hit => @hit, lookup_miss => @missed, delete => @delete, iterate => @iterate) -> $op {
            say join "\t", $engine, $n, $op.key, median($op.value).fmt('%.2f'), $rss;
        }
    }
}
