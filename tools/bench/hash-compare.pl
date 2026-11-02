#!/usr/bin/env perl
# Ratio tables with spread from the hash benchmarks' TSVs.
#
# Usage: tools/bench/hash-compare.pl c.tsv zig.tsv [other.tsv ...]
#
# The first file is the baseline (the C engine); every further file is
# compared against it. Prints one markdown table per operation (in the
# order first seen): rows are the sizes (numeric order), one column per
# compared file, each cell
#
#     ratio [other_min-other_max / base_min-base_max]
#
# where ratio = other_median / base_median (below 1 the compared engine is
# faster) and min-max is the spread of the runs, so the noise band sits
# next to every median. A size or operation missing on either side is "-".
#
# Input lines: engine<TAB>size<TAB>op<TAB>ns_per_op<TAB>mem[<TAB>ns_min<TAB>ns_max]
# (tools/bench/hash-bench.nqp and `zig build hash-bench` emit all seven
# columns: the median of the runs, then the fastest and slowest run). The
# script also accepts one line per run (five columns, several lines per
# size and op): the median is then taken over the lines (the upper middle
# for an even count, as the harnesses do) and the spread is their min-max.
# A five-column line on its own is a run of one, with no spread.
use strict;
use warnings;

die "usage: $0 base.tsv other.tsv [other.tsv ...]\n" if @ARGV < 2;

my (@ops, %op_seen);

sub load {
    my ($path) = @_;
    open my $fh, '<', $path or die "$0: $path: $!\n";
    my %runs;    # "$op\0$size" => { med => [...], lo => [...], hi => [...] }
    my %sizes;   # $op => { $size => 1 }
    while (my $line = <$fh>) {
        chomp $line;
        my @f = split /\t/, $line;
        next if @f < 5 || $f[3] !~ /^[\d.]+$/;
        my (undef, $size, $op, $ns) = @f;
        my ($lo, $hi) = @f >= 7 ? @f[5, 6] : ($ns, $ns);
        my $r = $runs{"$op\0$size"} //= { med => [], lo => [], hi => [] };
        push @{ $r->{med} }, $ns;
        push @{ $r->{lo} }, $lo;
        push @{ $r->{hi} }, $hi;
        $sizes{$op}{$size} = 1;
        push @ops, $op unless $op_seen{$op}++;
    }
    close $fh;
    my %stats;
    for my $k (keys %runs) {
        my $r = $runs{$k};
        my @m = sort { $a <=> $b } @{ $r->{med} };
        my ($lo) = sort { $a <=> $b } @{ $r->{lo} };
        my ($hi) = sort { $b <=> $a } @{ $r->{hi} };
        $stats{$k} = { med => $m[@m / 2], lo => $lo, hi => $hi };
    }
    return { stats => \%stats, sizes => \%sizes };
}

my @tables = map { load($_) } @ARGV;
my ($base, @others) = @tables;
my @labels = map { (my $l = $_) =~ s{.*/}{}; $l =~ s{\.tsv$}{}; "$l / base" } @ARGV[1 .. $#ARGV];

for my $op (@ops) {
    my %sizes;
    for my $t (@tables) { $sizes{$_} = 1 for keys %{ $t->{sizes}{$op} // {} } }
    print "### $op\n\n";
    print "| size |", (map { " $_ |" } @labels), "\n";
    print "|---:|", ("---:|" x @labels), "\n";
    for my $size (sort { $a <=> $b } keys %sizes) {
        my $bs = $base->{stats}{"$op\0$size"};
        my @cells;
        for my $o (@others) {
            my $z = $o->{stats}{"$op\0$size"};
            if (!$bs || !$z || $bs->{med} == 0) {
                push @cells, '-';
                next;
            }
            push @cells, sprintf '%.2f [%.2f-%.2f / %.2f-%.2f]',
                $z->{med} / $bs->{med}, $z->{lo}, $z->{hi}, $bs->{lo}, $bs->{hi};
        }
        print "| $size |", (map { " $_ |" } @cells), "\n";
    }
    print "\n";
}
