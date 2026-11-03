#!/usr/bin/env perl
# The hash layout bake-off scoreboard from tools/bench/hash-bakeoff.sh's
# raw.tsv.
#
# Usage: tools/bench/hash-bakeoff.pl raw.tsv [--base=0] [--win=0.90]
#
# Input lines: round<TAB>strategy<TAB>size<TAB>op<TAB>ns<TAB>rss<TAB>ns_min<TAB>ns_max,
# one per round, strategy, size and op (ns is the median of that round's
# runs, as tools/bench/hash-bench.nqp emits it; ns_min and ns_max are read
# but not used: the spread here is across rounds).
#
# Per (strategy, size, op): the median of the round medians (the upper
# middle for an even count, as the harnesses take it), the min and max of
# the round medians, and the median rss. The ratio is the cell's median
# over the base strategy's (--base, default 0); below 1 the strategy is
# faster. The verdict is `win` when the ratio is at or below --win
# (default 0.90) and the spreads are disjoint (the strategy's slowest round
# faster than the base's fastest), `n/a` when the strategy or the base has
# no cell there, else `-`. Size 4 is warm-up and never judged (always `-`).
#
# Output: markdown, one table per op in the fixed order insert, lookup_hit,
# lookup_miss, delete, iterate, insert_nth, bulk_load, overwrite, clone,
# iterate_delete (then any other op, by name); rows are sizes (numeric
# order), one column per strategy (numeric order), each cell
#
#     ratio [min-max] mem R verdict
#
# with min-max the strategy's round medians in ns and R its median rss over
# the base's (`-` when the base's is 0). Then "## Blocks", one line per
# strategy other than the base:
#
#   - sN: OP A-B             a maximal run of two or more adjacent ladder
#                            sizes on which OP wins, from A to B
#   - sN (multi-op): OP+OP A-B
#                            a run of two or more adjacent ladder sizes on
#                            which every op named wins (two or more ops),
#                            maximal: no neighbouring size where all of them
#                            win too
#   - sN: none
#
# The ladder, in order, is 16 32 63 64 65 128 256 1024 16384: sizes are
# adjacent when they are neighbours in this list (both measured). 49 and 97
# are resize cells, judged but never part of a block; 4 is never judged.
# A block needs two or more adjacent winning sizes: a lone winning size is
# reported in its table but never listed as a block.
use strict;
use warnings;

my $base = 0;
my $win = 0.90;
my @files;
for my $a (@ARGV) {
    if ($a =~ /^--base=(\d+)$/) { $base = $1 }
    elsif ($a =~ /^--win=([\d.]+)$/) { $win = $1 }
    elsif ($a =~ /^--/) { die "$0: unknown option $a\n" }
    else { push @files, $a }
}
die "usage: $0 raw.tsv [--base=0] [--win=0.90]\n" unless @files == 1;

my @OP_ORDER = qw(insert lookup_hit lookup_miss delete iterate insert_nth
                  bulk_load overwrite clone iterate_delete);
my @LADDER = (16, 32, 63, 64, 65, 128, 256, 1024, 16384);
my $WARMUP = 4;

# "$strategy\0$size\0$op" => { ns => [...], rss => [...] }
my (%runs, %strategies, %sizes_of_op, %ops);
open my $fh, '<', $files[0] or die "$0: $files[0]: $!\n";
while (my $line = <$fh>) {
    chomp $line;
    my @f = split /\t/, $line;
    next if @f < 6 || $f[4] !~ /^[\d.]+$/;
    my (undef, $strategy, $size, $op, $ns, $rss) = @f;
    my $r = $runs{"$strategy\0$size\0$op"} //= { ns => [], rss => [] };
    push @{ $r->{ns} }, $ns;
    push @{ $r->{rss} }, $rss;
    $strategies{$strategy} = 1;
    $sizes_of_op{$op}{$size} = 1;
    $ops{$op} = 1;
}
close $fh;
die "$0: base strategy $base has no rows in $files[0]\n" unless $strategies{$base};

sub median { my @s = sort { $a <=> $b } @_; $s[@s / 2] }

my %stats;
for my $k (keys %runs) {
    my @ns = sort { $a <=> $b } @{ $runs{$k}{ns} };
    $stats{$k} = { med => median(@ns), lo => $ns[0], hi => $ns[-1], rss => median(@{ $runs{$k}{rss} }) };
}

my @strategies = sort { $a <=> $b } keys %strategies;
my %fixed = map { $_ => 1 } @OP_ORDER;
my @ops = ((grep { $ops{$_} } @OP_ORDER), sort grep { !$fixed{$_} } keys %ops);

# $verdict{$strategy}{$op}{$size}
my %verdict;
sub judge {
    my ($s, $b, $size) = @_;
    return 'n/a' unless $s && $b;
    return '-' if $size == $WARMUP || $b->{med} == 0;
    my $ratio = $s->{med} / $b->{med};
    return ($ratio <= $win + 1e-9 && $s->{hi} < $b->{lo}) ? 'win' : '-';
}

print "# Hash layout bake-off\n\n";
print "Base strategy $base; a cell wins at ratio <= $win with the round spreads disjoint.\n";
print "Cells: `ratio [min-max of the round medians, ns] mem rss-ratio verdict`.\n\n";
for my $op (@ops) {
    print "### $op\n\n";
    print "| size |", (map { " s$_ |" } @strategies), "\n";
    print "|---:|", ("---:|" x @strategies), "\n";
    for my $size (sort { $a <=> $b } keys %{ $sizes_of_op{$op} }) {
        my $b = $stats{"$base\0$size\0$op"};
        my @cells;
        for my $strategy (@strategies) {
            my $s = $stats{"$strategy\0$size\0$op"};
            my $v = judge($s, $b, $size);
            $verdict{$strategy}{$op}{$size} = $v;
            if ($v eq 'n/a') { push @cells, 'n/a'; next }
            my $ratio = $b->{med} == 0 ? '-' : sprintf '%.2f', $s->{med} / $b->{med};
            my $mem = $b->{rss} == 0 ? '-' : sprintf '%.2f', $s->{rss} / $b->{rss};
            push @cells, sprintf '%s [%.2f-%.2f] mem %s %s', $ratio, $s->{lo}, $s->{hi}, $mem, $v;
        }
        print "| $size |", (map { " $_ |" } @cells), "\n";
    }
    print "\n";
}

# Blocks: runs of two or more adjacent ladder sizes.
sub wins { my ($strategy, $op, $size) = @_; ($verdict{$strategy}{$op}{$size} // '') eq 'win' }

print "## Blocks\n\n";
my @others = grep { $_ != $base } @strategies;
print "none\n" unless @others;
for my $strategy (@others) {
    my @lines;
    for my $op (@ops) {
        my $i = 0;
        while ($i < @LADDER) {
            if (!wins($strategy, $op, $LADDER[$i])) { $i++; next }
            my $j = $i;
            $j++ while $j + 1 < @LADDER && wins($strategy, $op, $LADDER[$j + 1]);
            push @lines, "- s$strategy: $op $LADDER[$i]-$LADDER[$j]" if $j > $i;
            $i = $j + 1;
        }
    }
    # Multi-op: every run [i, j] whose winning-op intersection has two or
    # more ops and cannot be extended by a neighbour where all of them win.
    my @won = map { my $size = $_; +{ map { $_ => 1 } grep { wins($strategy, $_, $size) } @ops } } @LADDER;
    my $all_in = sub { my ($set, $k) = @_; $k >= 0 && $k < @LADDER && !grep { !$won[$k]{$_} } @$set };
    for my $i (0 .. $#LADDER) {
        for my $j ($i + 1 .. $#LADDER) {
            my @common = grep { my $op = $_; !grep { !$won[$_]{$op} } $i .. $j } @ops;
            last if @common < 2;
            next if $all_in->(\@common, $i - 1) || $all_in->(\@common, $j + 1);
            # Maximal in the op set too: a longer run with the same ops is
            # caught above; a shorter run with more ops is its own block.
            push @lines, "- s$strategy (multi-op): " . join('+', @common) . " $LADDER[$i]-$LADDER[$j]";
        }
    }
    push @lines, "- s$strategy: none" unless @lines;
    print "$_\n" for @lines;
}
