#!/usr/bin/env perl
# Fixture test of tools/bench/hash-stats.pl: three synthetic stats files
# (site ids differ per file, one is header-only), a fake addr2line on PATH,
# counts summed per site across files, census labels, an unmapped site, the
# `other` site, the share columns and the Hash share section. The second part
# needs a stats-build moar and is skipped unless HASH_STATS_MOAR names one
# (an nqp-m is run against its lib, see the SKIP block):
#   HASH_STATS_MOAR=<prefix>/bin/moar prove tools/bench/t/hash-stats.t
# Run: prove tools/bench/t/hash-stats.t
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Basename qw(dirname);
use File::Spec;
use Test::More;

my $script = File::Spec->catfile(dirname(__FILE__), '..', 'hash-stats.pl');
my $tmp = tempdir(CLEANUP => 1);
my $dir = "$tmp/stats";
mkdir $dir or die "$dir: $!";

# The fake addr2line: function, then file:line, by the offset (the last
# argument, as in `addr2line -e LIB -f -C 0x<offset>`).
my $bin = "$tmp/bin";
mkdir $bin or die;
open my $fh, '>', "$bin/addr2line" or die;
print $fh <<'SH';
#!/bin/sh
for last; do :; done
case "$last" in
    0x63)  echo MVM_vm_create_instance; echo /build/MoarVM/src/moar.c:203 ;;
    0xc7)  echo some_other_function;    echo src/foo.c:7 ;;
    0x12b) echo bind_key;               echo src/6model/reprs/MVMHash.c:115 ;;
    *)     echo '??'; echo '??:0' ;;
esac
SH
close $fh;
chmod 0755, "$bin/addr2line";
$ENV{PATH} = "$bin:$ENV{PATH}";

sub write_file {
    my ($name, @lines) = @_;
    open my $o, '>', "$dir/$name" or die "$name: $!";
    print $o map { join("\t", @$_) . "\n" } @lines;
    close $o;
}
sub header {
    my ($cmd, $pid, $total) = @_;
    return ([ "# cmdline: $cmd" ], [ "# pid: $pid" ], [ '# tsc_hz: 1000000' ],
            [ "# total_cycles: $total" ], [ '# libmoar: /x/libmoar.so' ]);
}

# a: s1 at id 0, other_function at id 1, bind_key at id 2.
write_file('1.tsv', header('/usr/bin/moar --libpath=x rakudo.moarvm -e 1', 1, 100000),
    [ 'site', 0, '64' ], [ 'site', 1, 'c8' ], [ 'site', 2, '12c' ],
    [ 'op', 0, 'insert', 10, 1000 ], [ 'op', 0, 'fetch_hit', 4, 400 ],
    [ 'fetch', 0, 'hit', 1, 3, 300 ], [ 'fetch', 0, 'hit', 5, 1, 100 ],
    [ 'fetch', 0, 'miss', 5, 2, 50 ],
    [ 'op', 1, 'fetch_hit', 5, 500 ],
    [ 'op', 2, 'insert', 20, 2000 ], [ 'op', 2, 'grow', 1, 300 ],
    [ 'build', 0, 0, 3 ], [ 'build', 2, 9, 1 ],
    [ 'demolish', 2, 0, 1, 4, 2 ]);
# b: the same sites with the ids swapped, and the `other` site 255.
write_file('2.tsv', header('/usr/bin/moar --libpath=x rakudo.moarvm -e 2', 2, 50000),
    [ 'site', 0, '12c' ], [ 'site', 1, '64' ],
    [ 'op', 1, 'insert', 5, 500 ],
    [ 'op', 0, 'delete_hit', 2, 100 ],
    [ 'fetch', 1, 'hit', 5, 4, 200 ], [ 'fetch', 1, 'miss', 9, 1, 50 ],
    [ 'op', 255, 'fetch_miss', 3, 150 ],
    [ 'build', 1, 0, 2 ]);
# c: a process that built no table.
write_file('3.tsv', header('/usr/bin/moar nqp.moarvm', 3, 70000));

my $lib = "$tmp/libmoar.so";
my $out = qx{$^X $script $dir --lib=$lib 2>&1};
is $?, 0, 'hash-stats.pl exits 0' or diag $out;

like $out, qr/^### s1 MVM_vm_create_instance \(src\/moar\.c:203\)$/m, 'a site mapped to its census label';
like $out, qr/^\| insert \| 15 \| 1500 \| 100\.0 \| /m, 'insert counts and cycles summed across files (ids differ per file)';
like $out, qr/^\| fetch_hit \| 4 \| 400 \| 100\.0 \| /m, 'a row of one file only';
like $out, qr/^### s5 bind_key \(src\/6model\/reprs\/MVMHash\.c:115\)$/m, 'bind_key is s5';
like $out, qr/^\| insert \| 20 \| 2000 \| 100\.0 \| /m, 'a second site, its own insert row';
like $out, qr/^### some_other_function\@src\/foo\.c:7$/m, 'an unmapped site prints function@file:line';
like $out, qr/^### other$/m, 'site 255 is other';
like $out, qr/^\| grow \| 1 \| 300 \| 300\.0 \| \(in insert\) \| \(in insert\) \|$/m, 'grow is a breakdown of insert, outside the shares';
like $out, qr/^- build: <=4=5$/m, 'build histogram of s1 summed across files (3 + 2)';
like $out, qr/^- build: >16384=1$/m, 'build histogram: the more bucket';
like $out, qr/^- demolish set 0 rung 1: <=65=2$/m, 'demolish histogram';
like $out, qr/^Files: 3 \(1 header-only\)$/m, 'file count with header-only files';

like $out, qr/^Lookups by table size/m, 'a Lookups by table size block';
like $out, qr/^\| <=16 \| 3 \| 0 \| 300 \| 42\.9 \|$/m, 'bucket <=16: hits, misses, cycles, share';
like $out, qr/^\| <=128 \| 5 \| 2 \| 350 \| 50\.0 \|$/m, 'bucket <=128 summed across files (ids differ per file)';
like $out, qr/^\| >16384 \| 0 \| 1 \| 50 \| 7\.1 \|$/m, 'the more bucket';
like $out, qr/^- at or above 65 entries: 72\.7% of fetches, 57\.1% of fetch cycles$/m, 'share at or above 65';
like $out, qr/^- at or above 128 entries: 72\.7% of fetches, 57\.1% of fetch cycles$/m, 'share at or above 128';
my ($blk) = $out =~ /^Lookups by table size[^\n]*\n\n((?:\|[^\n]*\n)+)/m;
my $bsum = 0;
$bsum += $1 while $blk =~ /^\| (?:<=|>)\d+ \| \d+ \| \d+ \| \d+ \| ([\d.]+) \|$/mg;
cmp_ok abs($bsum - 100), '<', 0.2, "bucket shares of a site sum to 100 (got $bsum)";

# The share-of-hash column sums to 100 within rounding.
my $sum = 0;
$sum += $1 while $out =~ /^\| (?:insert|overwrite|fetch_hit|fetch_miss|delete_hit|delete_miss|iter_start|iter_step|copy|build|demolish) \| \d+ \| \d+ \| [\d.]+ \| ([\d.]+) \| [\d.]+ \|$/mg;
cmp_ok abs($sum - 100), '<', 0.5, "share of hash cycles sums to 100 (got $sum)";
# Hash cycles 1000+400+500+2000+500+100+150 = 4650 over total 150000.
like $out, qr/^Hash cycles: 4650 of 150000 \(3\.1%\)$/m, 'hash cycles of total (header-only file excluded)';

my ($share) = $out =~ /^## Hash share\n(.*)\z/ms;
ok defined $share, 'a Hash share section ends the output';
like $share, qr/^\| rakudo\.moarvm -e \| 2 \| 0 \| 150000 \| 4650 \| 3\.1 \|$/m, 'program rakudo.moarvm -e';
like $share, qr/^\| nqp\.moarvm \| 1 \| 1 \| 0 \| 0 \| - \|$/m, 'program nqp.moarvm: header-only file counted apart';

my $tsv = "$tmp/merged.tsv";
$out = qx{$^X $script $dir --lib=$lib --tsv=$tsv 2>&1};
is $?, 0, '--tsv exits 0';
open my $in, '<', $tsv or die "$tsv: $!";
my @rows = <$in>;
close $in;
ok scalar(grep { $_ eq "op\ts1\tinsert\t15\t1500\n" } @rows), 'merged tsv: summed insert row of s1';
ok scalar(grep { $_ eq "build\ts1\t0\t5\n" } @rows), 'merged tsv: summed histogram';
ok scalar(grep { $_ eq "fetch\ts1\thit\t5\t5\t300\n" } @rows), 'merged tsv: summed fetch row';

# An empty directory is an error.
my $empty = "$tmp/empty";
mkdir $empty;
$out = qx{$^X $script $empty --lib=$lib 2>&1};
isnt $?, 0, 'no files: non-zero exit';
like $out, qr/no \*\.tsv files in \Q$empty\E/, 'no files: the message';

SKIP: {
    # `moar --version` and `--help` exit before any table is built, so the
    # exit handler is never registered and no file is written; an nqp that
    # runs against the stats libmoar builds tables at startup. HASH_STATS_NQP
    # names it (default: the tune prefix's nqp-m), run with the stats
    # prefix's lib (next to HASH_STATS_MOAR's bin) in LD_LIBRARY_PATH.
    my $moar = $ENV{HASH_STATS_MOAR};
    skip 'set HASH_STATS_MOAR to a stats-build moar', 7 unless $moar;
    my $nqp = $ENV{HASH_STATS_NQP} // '/tmp/claude-1000/tune-zig-prefix/bin/nqp-m';
    skip "no nqp at $nqp (set HASH_STATS_NQP)", 7 unless -x $nqp;
    local $ENV{LD_LIBRARY_PATH} = File::Spec->catdir(dirname($moar), '..', 'lib');
    my $stderr = "$tmp/err.txt";

    qx{$moar --version >/dev/null 2>&1};
    is $?, 0, 'moar --version exits 0';

    local $ENV{MVM_HASH_STATS} = '/nonexistent/dir';
    qx{$nqp -e 1 2>$stderr};
    is $?, 0, 'an unwritable MVM_HASH_STATS does not change the exit status';
    open my $e, '<', $stderr or die;
    my @err = <$e>;
    close $e;
    is scalar(@err), 1, 'exactly one stderr line' or diag @err;
    like $err[0] // '', qr/MVM_HASH_STATS/, 'the line names MVM_HASH_STATS';

    my $d = "$tmp/real";
    local $ENV{MVM_HASH_STATS} = $d;
    qx{$nqp -e 1 2>&1};
    is $?, 0, 'nqp -e 1 with MVM_HASH_STATS exits 0';
    my @files = glob("$d/*.tsv");
    is scalar(@files), 1, 'one tsv file' or diag "@files";
    open my $t, '<', $files[0] or die;
    my $first = <$t>;
    close $t;
    like $first // '', qr/^# cmdline:/, 'the first line is the cmdline header';
}

done_testing;
