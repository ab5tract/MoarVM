#!/usr/bin/env perl
# Fixture test of tools/bench/hash-bakeoff.pl: a 2-strategy, 3-size, 2-op
# raw file in, the ratios, verdicts and the detected blocks out.
# Run: prove tools/bench/t/hash-bakeoff.t
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Basename qw(dirname);
use File::Spec;
use Test::More;

my $script = File::Spec->catfile(dirname(__FILE__), '..', 'hash-bakeoff.pl');
my $dir = tempdir(CLEANUP => 1);

sub write_tsv {
    my ($name, @lines) = @_;
    my $path = "$dir/$name";
    open my $fh, '>', $path or die "$path: $!";
    print $fh map { join("\t", @$_) . "\n" } @lines;
    close $fh;
    return $path;
}

sub bakeoff {
    my @args = @_;
    my $out = qx{$^X $script @args 2>&1};
    is $?, 0, "hash-bakeoff.pl @args exits 0" or diag $out;
    return $out;
}

# Rows: round strategy size op ns rss ns_min ns_max. Three rounds; per
# (strategy, size, op) the round medians below give the median and the
# min-max spread named in the comments.
my @rows;
sub cell {
    my ($strategy, $size, $op, $rss, @ns) = @_;
    my $round = 0;
    push @rows, [ ++$round, $strategy, $size, $op, $_, $rss, $_ - 0.25, $_ + 0.25 ] for @ns;
}
cell(0, 16, 'lookup_hit', 1000, 10, 11, 9);    # 10 [9-11]
cell(0, 32, 'lookup_hit', 1000, 20, 21, 19);   # 20 [19-21]
cell(0, 63, 'lookup_hit', 1000, 30, 31, 29);   # 30 [29-31]
cell(1, 16, 'lookup_hit', 500, 8, 8.5, 7.5);   # 0.80, disjoint: win
cell(1, 32, 'lookup_hit', 500, 16, 17, 15);    # 0.80, disjoint: win
cell(1, 63, 'lookup_hit', 500, 27, 30, 26);    # 0.90, spreads overlap: -
cell(0, 16, 'insert', 1000, 50, 52, 48);       # 50 [48-52]
cell(0, 32, 'insert', 1000, 60, 62, 58);       # 60 [58-62]
cell(0, 63, 'insert', 1000, 70, 72, 68);       # 70 [68-72]
cell(1, 16, 'insert', 2000, 46, 47, 45);       # 0.92, disjoint but above 0.90: -
cell(1, 32, 'insert', 2000, 30, 31, 29);       # 0.50: win (a lone size, no block)
# (strategy 1 has no insert row at 63: n/a)
my $raw = write_tsv('raw.tsv', @rows);

my $out = bakeoff($raw);
like $out, qr/^### insert$/m, 'one table per op: insert';
like $out, qr/^### lookup_hit$/m, 'one table per op: lookup_hit';
ok index($out, '### insert') < index($out, '### lookup_hit'), 'ops in the fixed order';
like $out, qr/^\| size \| s0 \| s1 \|$/m, 'one column per strategy';
like $out, qr/^\| 16 \| 1\.00 \[9\.00-11\.00\] mem 1\.00 - \| 0\.80 \[7\.50-8\.50\] mem 0\.50 win \|$/m,
    'lookup_hit 16: ratio, spread, memory ratio, win';
like $out, qr/^\| 32 \| 1\.00 \[19\.00-21\.00\] mem 1\.00 - \| 0\.80 \[15\.00-17\.00\] mem 0\.50 win \|$/m,
    'lookup_hit 32: win';
like $out, qr/^\| 63 \| 1\.00 \[29\.00-31\.00\] mem 1\.00 - \| 0\.90 \[26\.00-30\.00\] mem 0\.50 - \|$/m,
    'lookup_hit 63: overlapping spreads are no win';
like $out, qr/^\| 16 \| 1\.00 \[48\.00-52\.00\] mem 1\.00 - \| 0\.92 \[45\.00-47\.00\] mem 2\.00 - \|$/m,
    'insert 16: a ratio above --win is no win';
like $out, qr/^\| 32 \| 1\.00 \[58\.00-62\.00\] mem 1\.00 - \| 0\.50 \[29\.00-31\.00\] mem 2\.00 win \|$/m,
    'insert 32: win';
like $out, qr/^\| 63 \| 1\.00 \[68\.00-72\.00\] mem 1\.00 - \| n\/a \|$/m, 'a missing cell is n/a';
ok index($out, '| 16 | 1.00 [9.00') < index($out, '| 32 | 1.00 [19.00'), 'sizes in numeric order';

my ($blocks) = $out =~ /^## Blocks\n(.*)\z/ms;
ok defined $blocks, 'a Blocks section ends the output';
like $blocks, qr/^- s1: lookup_hit 16-32$/m, 'the one block: lookup_hit 16-32';
is scalar(() = $blocks =~ /^- s1(?: \(multi-op\))?: \S+ \d+-\d+$/mg), 1, 'exactly one block';
unlike $blocks, qr/insert/, 'a lone winning size is no block';
unlike $blocks, qr/^- s0/m, 'the base strategy has no blocks line';

# --win=0.95: insert 16 now wins too, so insert has the block 16-32 and
# both ops win on 16-32, a multi-op block.
$out = bakeoff($raw, '--win=0.95');
like $out, qr/^\| 16 \| 1\.00 \[48\.00-52\.00\] mem 1\.00 - \| 0\.92 \[45\.00-47\.00\] mem 2\.00 win \|$/m,
    '--win=0.95: insert 16 wins';
like $out, qr/^- s1: insert 16-32$/m, '--win=0.95: insert block';
like $out, qr/^- s1: lookup_hit 16-32$/m, '--win=0.95: lookup_hit block';
like $out, qr/^- s1 \(multi-op\): insert\+lookup_hit 16-32$/m, '--win=0.95: multi-op block';

# --base=1: ratios against strategy 1.
$out = bakeoff($raw, '--base=1');
like $out, qr/^\| size \| s0 \| s1 \|$/m, '--base=1: columns unchanged';
like $out, qr/^\| 16 \| 1\.25 \[9\.00-11\.00\] mem 2\.00 - \| 1\.00 \[7\.50-8\.50\] mem 1\.00 - \|$/m,
    '--base=1: ratios against strategy 1';
like $out, qr/^- s0: none$/m, '--base=1: s0 has no blocks';

# Size 4 is warm-up (never judged) and 49 is a resize cell (judged, never
# in a block); 16 and 64 are not adjacent ladder sizes.
@rows = ();
for my $size (4, 16, 49, 64) {
    cell(0, $size, 'delete', 0, 10, 10, 10);
    cell(1, $size, 'delete', 0, 5, 5, 5);
}
$out = bakeoff(write_tsv('edges.tsv', @rows));
like $out, qr/^\| 4 \| 1\.00 \[10\.00-10\.00\] mem - - \| 0\.50 \[5\.00-5\.00\] mem - - \|$/m,
    'size 4 is never judged; a zero base memory is -';
like $out, qr/^\| 49 \| .* \| 0\.50 \[5\.00-5\.00\] mem - win \|$/m, 'size 49 is judged';
like $out, qr/^- s1: none$/m, 'no block across a resize size or non-adjacent sizes';

# Only the base strategy: a single column of 1.00 and no blocks.
@rows = ();
cell(0, 16, 'insert', 100, 3, 4, 2);
cell(0, 32, 'insert', 100, 3, 4, 2);
$out = bakeoff(write_tsv('single.tsv', @rows));
like $out, qr/^\| 16 \| 1\.00 \[2\.00-4\.00\] mem 1\.00 - \|$/m, 'single strategy: ratio 1.00';
like $out, qr/^## Blocks\n\nnone\n/m, 'single strategy: no blocks';

# The base strategy missing is an error.
my $err = qx{$^X $script --base=7 $raw 2>&1};
isnt $?, 0, 'an absent base strategy is an error';
like $err, qr/base strategy 7/, 'the error names the base strategy';

done_testing;
