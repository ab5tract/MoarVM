#!/usr/bin/env perl
# Test of tools/bench/gc/oracle.sh. One real run of the C oracle prefix
# against itself (crc-sequential.raku --volume=1000) must pass; then the logs
# of that run, altered in one `promoted` value, must fail in --compare-only
# mode with the differing line printed: altered in one head log the side is
# "not repeatable" (exit 2), altered in all three head logs base and head
# differ (exit 1). A malformed line fails the format guard (exit 3).
# Run: prove tools/bench/t/gc-oracle.t
# The prefix is $GC_ORACLE_PREFIX, else /tmp/claude-1000/gc-c-oracle (a
# -Dgc-debug=1 install); the test is skipped when it is missing.
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Basename qw(dirname);
use File::Spec;
use File::Copy qw(copy);
use Test::More;

my $script = File::Spec->rel2abs(File::Spec->catfile(dirname(__FILE__), '..', 'gc', 'oracle.sh'));
my $prefix = $ENV{GC_ORACLE_PREFIX} // '/tmp/claude-1000/gc-c-oracle';
plan skip_all => "$prefix/lib/libmoar.so missing" unless -e "$prefix/lib/libmoar.so";

my $dir = tempdir(CLEANUP => 1);

sub oracle {
    my @args = @_;
    my $out = qx{sh $script @args 2>&1};
    return ($? >> 8, $out);
}

# Case 1: the C oracle against itself.
my ($code, $out) = oracle("--base=$prefix", "--head=$prefix", '--volume=1000', '--tier=2', "--out=$dir/same");
is $code, 0, 'oracle.sh: gc-c-oracle against itself exits 0' or diag $out;
for my $f (map { ("base-$_.log", "head-$_.log") } 1 .. 3) {
    ok -s "$dir/same/$f", "$f written";
}

# Alter `promoted` on the first line whose value is nonzero.
sub alter {
    my ($path) = @_;
    open my $in, '<', $path or die "$path: $!";
    my @lines = <$in>;
    close $in;
    my $n;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ s/ promoted=([1-9][0-9]*) / ' promoted=' . ($1 + 1) . ' ' /e) {
            $n = $i + 1;
            last;
        }
    }
    die "$path: no nonzero promoted value" unless $n;
    open my $outf, '>', $path or die "$path: $!";
    print $outf @lines;
    close $outf;
    return ($n, $lines[$n - 1]);
}

sub copy_logs {
    my ($to) = @_;
    mkdir $to or die "$to: $!";
    copy("$dir/same/$_", "$to/$_") or die "$_: $!" for map { ("base-$_.log", "head-$_.log") } 1 .. 3;
}

SKIP: {
    skip 'case 1 failed; no logs to alter', 6 unless $code == 0;

    # Case 2a: one head log altered: the head side is not repeatable.
    copy_logs("$dir/one");
    my ($n, $line) = alter("$dir/one/head-2.log");
    chomp $line;
    ($code, $out) = oracle('--compare-only', '--tier=2', "--out=$dir/one");
    is $code, 2, 'one altered head log: exit 2' or diag $out;
    like $out, qr/not repeatable/, 'one altered head log: "not repeatable"';
    like $out, qr/\Q$line\E/, 'one altered head log: the differing line is printed';

    # Case 2b: the same alteration in all three head logs: base and head differ.
    copy_logs("$dir/all");
    alter("$dir/all/head-$_.log") for 1 .. 3;
    ($code, $out) = oracle('--compare-only', '--tier=2', "--out=$dir/all");
    is $code, 1, 'altered head side: exit 1' or diag $out;
    like $out, qr/line $n:/, 'altered head side: the differing line number';
    like $out, qr/\Q$line\E/, 'altered head side: the differing line is printed';

    # Format guard: a malformed line exits 3 and names it.
    copy_logs("$dir/bad");
    open my $fh, '>>', "$dir/bad/base-1.log" or die $!;
    print $fh "seq=x tid=1\n";
    close $fh;
    ($code, $out) = oracle('--compare-only', '--tier=2', "--out=$dir/bad");
    is $code, 3, 'malformed line: exit 3' or diag $out;
    like $out, qr/base-1\.log:\d+: seq=x tid=1/, 'malformed line: named';
}

# Misuse exits non-zero.
($code, $out) = oracle('--volume=1000');
isnt $code, 0, 'missing --out: non-zero exit';

done_testing;
