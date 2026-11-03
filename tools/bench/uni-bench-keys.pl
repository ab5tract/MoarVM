#!/usr/bin/env perl
# The key file of the unicode benchmark (tools/bench/uni-bench.nqp and
# `zig build uni-bench`): parses the static key arrays of
# src/strings/unicode_db.c textually and writes TSV rows `kind<TAB>name[<TAB>value]`
#   prop   per value of unicode_property_keypairs, its longest name (the long
#          form: Alphabetic over Alpha; a tie goes to the first in array
#          order); the value follows
#   alias  every other name of that array; the value follows
#   pval   1,024 keys ("<propcode>-<valuename>") of unicode_property_value_keypairs,
#          sampled with a fixed stride from those that look up in their own table
#          with a nonzero value code; rows are pval<TAB><propcode><TAB><valuename>
#   seq    every name of uni_seq_pairs (named sequences)
# Codepoint names are not in the file: both benchmarks harvest them at runtime.
#
# Usage: perl tools/bench/uni-bench-keys.pl src/strings/unicode_db.c > tools/bench/uni-bench-keys.tsv
use strict;
use warnings;

my $file = shift or die "usage: uni-bench-keys.pl src/strings/unicode_db.c\n";
open my $fh, '<', $file or die "$file: $!\n";
my $src = do { local $/; <$fh> };
close $fh;

# The (name, value) pairs of one array, in source order.
sub pairs {
    my ($array) = @_;
    $src =~ /static const MVMUnicodeNamedValue \Q$array\E\[\d+\] = \{(.*?)\n\};/s
        or die "uni-bench-keys.pl: array $array not found in $file\n";
    my $body = $1;
    my @pairs;
    while ($body =~ /\{"([^"\\]*)",(-?\d+)\}/g) { push @pairs, [$1, $2] }
    die "uni-bench-keys.pl: no pairs in $array\n" unless @pairs;
    return @pairs;
}

my (%count, @rows);
my @kp = pairs('unicode_property_keypairs');
my %long;    # value => index of its longest name, the first of equals
for my $i (0 .. $#kp) {
    my ($name, $value) = @{ $kp[$i] };
    $long{$value} = $i if !defined $long{$value} || length($name) > length($kp[ $long{$value} ][0]);
}
for my $i (0 .. $#kp) {
    my ($name, $value) = @{ $kp[$i] };
    my $kind = $long{$value} == $i ? 'prop' : 'alias';
    push @rows, "$kind\t$name\t$value";
    $count{$kind}++;
}

my @pv = grep { $_->[0] =~ /^(\d+)-/ && $1 == ($_->[1] >> 24) && ($_->[1] & 0xFFFFFF) } pairs('unicode_property_value_keypairs');
my $stride = int(@pv / 1024);
for (my $i = 0, my $n = 0; $n < 1024 && $i < @pv; $i += $stride, $n++) {
    my ($key) = @{ $pv[$i] };
    $key =~ /^(\d+)-(.+)$/ or die "uni-bench-keys.pl: malformed property value key $key\n";
    push @rows, "pval\t$1\t$2";
    $count{pval}++;
}

for my $p (pairs('uni_seq_pairs')) {
    push @rows, "seq\t$p->[0]";
    $count{seq}++;
}

my %min = (prop => 100, alias => 100, pval => 1024, seq => 3000);
for my $k (sort keys %min) {
    die "uni-bench-keys.pl: only " . ($count{$k} // 0) . " $k rows, expected at least $min{$k}\n"
        if ($count{$k} // 0) < $min{$k};
}
print "$_\n" for @rows;
