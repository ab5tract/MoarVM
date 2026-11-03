#!/usr/bin/env perl
# The harness's --hint option on a real nqp: the default is hint 0 (engine
# column zig-s0, the same as --hint=0), --hint=size is the presized variant
# (zig-s0-presized), anything else is an error. Needs an nqp that maps
# nqp::hashstrategy; skipped unless HASH_BENCH_NQP names one:
#   HASH_BENCH_NQP=<prefix>/bin/nqp-m prove tools/bench/t/hash-bench-hint.t
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use Test::More;

my $nqp = $ENV{HASH_BENCH_NQP};
plan skip_all => 'set HASH_BENCH_NQP to an nqp that maps nqp::hashstrategy' unless $nqp;

my $harness = File::Spec->catfile(dirname(__FILE__), '..', 'hash-bench.nqp');

sub engines {
    my @args = @_;
    my $out = qx{$nqp $harness --sizes=16 --runs=1 @args 2>&1};
    is $?, 0, "hash-bench.nqp @args exits 0" or diag $out;
    my %e = map { (split /\t/)[0] => 1 } grep { /\t/ } split /\n/, $out;
    my %ops = map { (split /\t/)[2] => 1 } grep { /\t/ } split /\n/, $out;
    return ([ sort keys %e ], \%ops);
}

my ($e, $ops) = engines();
is_deeply $e, ['zig-s0'], 'default: hint 0, engine zig-s0';
ok $ops->{$_}, "default emits $_" for qw(insert overwrite clone iterate_delete);
($e) = engines('--hint=0');
is_deeply $e, ['zig-s0'], '--hint=0 is the default';
($e) = engines('--hint=size');
is_deeply $e, ['zig-s0-presized'], '--hint=size: engine zig-s0-presized';
($e) = engines('--strategy=0', '--hint=size', '--engine=x');
is_deeply $e, ['x'], '--engine overrides the default engine name';

my $err = qx{$nqp $harness --sizes=16 --runs=1 --hint=7 2>&1};
isnt $?, 0, '--hint=7 is an error';
like $err, qr/unknown option --hint=7/, 'the error names the option';

done_testing;
