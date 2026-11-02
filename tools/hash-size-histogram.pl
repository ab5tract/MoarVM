#!/usr/bin/env perl
# Sum the per-process histogram lines written by the spike instrumentation
# (MVM_HASH_HISTOGRAM) and report the distribution of final string-hash sizes.
#
# Line format: all <8> mvmhash <8> attrstore <8>
# Buckets: 0, 1-4, 5-16, 17-64, 65-128, 129-256, 257-1024, 1025+
# Row "others" is all - mvmhash - attrstore.
#
# Usage: hash-size-histogram.pl FILE...
use strict;
use warnings;

die "usage: $0 FILE...\n" unless @ARGV;

my @labels = ('0', '1-4', '5-16', '17-64', '65-128', '129-256', '257-1024', '1025+');
my %row = (all => [(0) x 8], mvmhash => [(0) x 8], attrstore => [(0) x 8]);
my $lines = 0;

for my $file (@ARGV) {
    open my $fh, '<', $file or die "$file: $!\n";
    while (<$fh>) {
        next unless /\S/;
        my @f = split ' ';
        die "$file:$.: expected 27 fields, got " . scalar(@f) . "\n" if @f != 27;
        for my $r (0 .. 2) {
            my ($name, @n) = @f[$r * 9 .. $r * 9 + 8];
            die "$file:$.: unexpected row '$name'\n" unless $row{$name};
            $row{$name}[$_] += $n[$_] for 0 .. 7;
        }
        $lines++;
    }
    close $fh;
}

$row{others} = [ map { $row{all}[$_] - $row{mvmhash}[$_] - $row{attrstore}[$_] } 0 .. 7 ];

print "processes: $lines\n";
printf "%-10s", 'row';
printf " %10s", $_ for @labels;
printf " %10s\n", 'total';
for my $name (qw(all mvmhash attrstore others)) {
    my $c = $row{$name};
    my $t = 0; $t += $_ for @$c;
    printf "%-10s", $name;
    printf " %10d", $_ for @$c;
    printf " %10d\n", $t;
}

# Cumulative coverage of final sizes 1..N as a percentage of tables with >= 1 entry.
my %upto = (64 => 3, 128 => 4, 256 => 5);   # last bucket index included
print "\ncoverage of sizes 1..N among non-empty tables\n";
printf "%-10s %10s %8s %8s %8s\n", 'row', 'nonempty', '<=64', '<=128', '<=256';
for my $name (qw(all mvmhash attrstore others)) {
    my $c = $row{$name};
    my $nonempty = 0; $nonempty += $c->[$_] for 1 .. 7;
    printf "%-10s %10d", $name, $nonempty;
    for my $n (64, 128, 256) {
        my $sum = 0; $sum += $c->[$_] for 1 .. $upto{$n};
        if ($nonempty) { printf " %7.3f%%", 100 * $sum / $nonempty }
        else           { printf " %8s", 'n/a' }
    }
    print "\n";
}
