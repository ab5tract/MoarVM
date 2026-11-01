#!/usr/bin/env perl
# Renumber the rulesets of a tools/tiler-table-generator.pl output into the
# canonical order used by tools/zig/tiler_table_generator.zig, so the two can
# be compared byte for byte. The Perl generator numbers rulesets in hash
# order, which changes from run to run; the canonical order sorts rulesets
# by their ascending rule-number lists.
#
# usage: perl tools/canonicalize-tile-table.pl <debug-output> <tile_pattern.h> > canonical.h
# where <debug-output> is the stdout of `tiler-table-generator.pl --debug`
# (it lists each ruleset's rules) and <tile_pattern.h> is the file it wrote.
use strict;
use warnings;

my ($debug_file, $header_file) = @ARGV;
die "usage: canonicalize-tile-table.pl <debug-output> <tile_pattern.h>\n" unless defined $header_file;

# ruleset number -> sorted rule numbers, from the "Rulesets:" listing
open my $dfh, '<', $debug_file or die "cannot open $debug_file: $!";
my (%rulesets, $in_rulesets);
while (my $line = <$dfh>) {
    if ($line =~ /^Rulesets:/) { $in_rulesets = 1; next }
    next unless $in_rulesets;
    next unless $line =~ /^(\d+) => (.*)$/;
    my ($nr, $list) = ($1, $2);
    $rulesets{$nr} = [ sort { $a <=> $b } grep { length } map { s/^\s+|\s+$//gr } split /,/, $list ];
}
close $dfh;

sub cmp_lists {
    my ($x, $y) = @_;
    for (my $i = 0; $i < @$x && $i < @$y; $i++) {
        my $c = $x->[$i] <=> $y->[$i];
        return $c if $c;
    }
    return @$x <=> @$y;
}
my @order = sort { cmp_lists($rulesets{$a}, $rulesets{$b}) } keys %rulesets;
my %newnum;
$newnum{ $order[$_] } = $_ for 0 .. $#order;

open my $hfh, '<', $header_file or die "cannot open $header_file: $!";
my @lines = <$hfh>;
chomp @lines;
close $hfh;

my @out;
my $i = 0;
while ($i < @lines) {
    my $line = $lines[$i];
    if ($line eq 'static const MVMint32 MVM_jit_tile_select[][3] = {') {
        push @out, $line;
        $i++;
        my @rows;
        while ($lines[$i] ne '};') {
            my ($rs, $sym, $rule) = $lines[$i] =~ /^  \{ (\d+), (\d+), (\d+) \},$/
                or die "bad select row: $lines[$i]";
            push @rows, [ $newnum{$rs}, $sym, $rule ];
            $i++;
        }
        push @out, map { sprintf('  { %d, %d, %d },', @$_) }
            sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @rows;
        push @out, $lines[$i++];
        next;
    }
    if ($line eq 'static MVMint32 MVM_jit_tile_state[][6] = {') {
        push @out, $line;
        $i++;
        my (@group, $head);
        my $flush = sub {
            push @out, map { sprintf('  { %s, %d, %d, %d, %d },', @$_) }
                sort { $a->[1] <=> $b->[1] || $a->[2] <=> $b->[2] } @group;
            @group = ();
        };
        while ($lines[$i] ne '};') {
            my ($h, $rs1, $rs2, $state, $best) =
                $lines[$i] =~ /^  \{ (MVM_JIT_\w+), (-?\d+), (-?\d+), (\d+), (-?\d+) \},$/
                or die "bad state row: $lines[$i]";
            if (!defined $head || $h ne $head) {
                $flush->() if @group;
                $head = $h;
            }
            push @group, [ $h, ($rs1 == -1 ? -1 : $newnum{$rs1}), ($rs2 == -1 ? -1 : $newnum{$rs2}), $newnum{$state}, $best ];
            $i++;
        }
        $flush->() if @group;
        push @out, $lines[$i++];
        next;
    }
    push @out, $line;
    $i++;
}
print "$_\n" for @out;
