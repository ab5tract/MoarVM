#!/usr/bin/env perl
# Fixture test of tools/bench/hash-compare.pl: two 3-line TSVs in, the
# ratio and spread strings out. Run: prove tools/bench/t/hash-compare.t
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Basename qw(dirname);
use File::Spec;
use Test::More;

my $script = File::Spec->catfile(dirname(__FILE__), '..', 'hash-compare.pl');
my $dir = tempdir(CLEANUP => 1);

sub write_tsv {
    my ($name, @lines) = @_;
    my $path = "$dir/$name";
    open my $fh, '>', $path or die "$path: $!";
    print $fh map { join("\t", @$_) . "\n" } @lines;
    close $fh;
    return $path;
}

sub compare {
    my @files = @_;
    my $out = qx{$^X $script @files 2>&1};
    is $?, 0, 'hash-compare.pl exits 0' or diag $out;
    return $out;
}

# Median plus spread columns (engine size op median mem min max).
my $c = write_tsv('c.tsv',
    [qw(c 64 lookup_hit 10.00 100 9.00 11.00)],
    [qw(c 64 delete 20.00 100 19.00 22.00)],
    [qw(c 1024 lookup_hit 8.00 900 7.50 8.50)],
);
my $zig = write_tsv('zig.tsv',
    [qw(zig 64 lookup_hit 12.00 50 11.50 13.00)],
    [qw(zig 64 delete 15.00 50 14.00 16.00)],
    [qw(zig 1024 lookup_hit 10.00 900 9.00 11.00)],
);
my $out = compare($c, $zig);
like $out, qr/^### lookup_hit$/m, 'one table per op: lookup_hit';
like $out, qr/^### delete$/m, 'one table per op: delete';
like $out, qr/^\| 64 \| 1\.20 \[11\.50-13\.00 \/ 9\.00-11\.00\] \|$/m, 'ratio and spread at 64';
like $out, qr/^\| 1024 \| 1\.25 \[9\.00-11\.00 \/ 7\.50-8\.50\] \|$/m, 'ratio and spread at 1024';
like $out, qr/^\| 64 \| 0\.75 \[14\.00-16\.00 \/ 19\.00-22\.00\] \|$/m, 'delete ratio below 1';
ok index($out, '### lookup_hit') < index($out, '### delete'), 'ops in first-seen order';
ok index($out, '| 64 | 1.20') < index($out, '| 1024 | 1.25'), 'sizes in numeric order';

# One line per run (five columns): median and min-max from the runs.
my $c_runs = write_tsv('c-runs.tsv',
    [qw(c 16 insert 3.00 0)],
    [qw(c 16 insert 1.00 0)],
    [qw(c 16 insert 2.00 0)],
);
my $zig_runs = write_tsv('zig-runs.tsv',
    [qw(zig 16 insert 1.50 0)],
    [qw(zig 16 insert 0.50 0)],
    [qw(zig 16 insert 1.00 0)],
);
$out = compare($c_runs, $zig_runs);
like $out, qr/^\| 16 \| 0\.50 \[0\.50-1\.50 \/ 1\.00-3\.00\] \|$/m, 'per-run lines: median ratio and min-max';

# A size missing on one side renders a dash.
my $zig_part = write_tsv('zig-part.tsv', [qw(zig 64 lookup_hit 12.00 50 11.50 13.00)]);
$out = compare($c, $zig_part);
like $out, qr/^\| 1024 \| - \|$/m, 'missing cell is a dash';

done_testing;
