#!/usr/bin/env perl
# The unicode lookup harness on a real nqp: --ops selects cells, an unknown
# op and a malformed key file are errors. Skipped unless UNI_BENCH_NQP names
# an nqp:
#   UNI_BENCH_NQP=<prefix>/bin/nqp-m prove tools/bench/t/uni-bench.t
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempfile);
use Test::More;

my $nqp = $ENV{UNI_BENCH_NQP};
plan skip_all => 'set UNI_BENCH_NQP to an nqp' unless $nqp;

my $harness = File::Spec->catfile(dirname(__FILE__), '..', 'uni-bench.nqp');

my $out = qx{$nqp $harness --runs=1 --sample=64 --ops=cpbyname_hit,propcode_miss 2>&1};
is $?, 0, 'exits 0' or diag $out;
my @rows = map { [ split /\t/ ] } grep { /\t/ } split /\n/, $out;
is scalar(@rows), 2, 'two rows';
is_deeply [ map { $_->[2] } @rows ], [qw(cpbyname_hit propcode_miss)], 'the selected ops, in order';
is $rows[0][0], 'zig', 'default engine zig';
is scalar(@{ $rows[0] }), 7, 'seven columns';
is $rows[0][1], 64, 'cpbyname_hit: size is the sample';
cmp_ok $rows[1][1], '>=', 100, 'propcode_miss: size is the property key count';
cmp_ok $rows[0][3], '>', 0, 'ns per op is positive';

$out = qx{$nqp $harness --runs=1 --sample=64 --ops=bogus 2>&1};
isnt $?, 0, '--ops=bogus is an error';
like $out, qr/bogus/, 'the error names the op';

my ($fh, $keys) = tempfile(UNLINK => 1);
print $fh "prop\tAlphabetic\t33\nbogus-row-without-tabs\n";
close $fh;
$out = qx{$nqp $harness --runs=1 --sample=64 --ops=propcode_hit --keys=$keys 2>&1};
isnt $?, 0, 'a malformed key row is an error';
like $out, qr/malformed/, 'the error says malformed';

($fh, $keys) = tempfile(UNLINK => 1);
print $fh "prop\tNoSuchPropertyName\t33\n";
close $fh;
$out = qx{$nqp $harness --runs=1 --ops=propcode_hit --keys=$keys 2>&1};
isnt $?, 0, 'a _hit cell with a missing key dies';
like $out, qr/propcode_hit: \d+ wrong answers/, 'the error names the cell';

done_testing;
