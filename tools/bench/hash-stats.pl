#!/usr/bin/env perl
# The report of the hash engine's own-table statistics (a -Dhash-stats=true
# build, docs/zig-build.md "Statistics"): merges every *.tsv a run of
# MVM_HASH_STATS=DIR left behind.
#
# Usage: tools/bench/hash-stats.pl DIR --lib=PATH/libmoar.so [--census]
#                                  [--tsv=OUT.tsv] > report.md
#
# Site ids are per process (interned by return address), so each file's
# `site` rows are resolved against --lib and the sites merged by what they
# resolve to: a census label (s1 ... p2 of traces/llm/bench/bakeoff-census.md)
# from the table below, else `function@file:line`; id 255 is `other`.
# The offset is a return address, so the lookup is for offset-1, the call
# instruction (the line of the call, not of the next statement). GNU
# addr2line cannot read this build's DWARF (LTO objects, clang 21); when it
# prints no file the same lookup is retried with llvm-addr2line.
#
# THE LINE TABLE IS SURVEY-GRADE. Several census sites share one function
# (MVM_vm_create_instance builds nine tables), so those rows are keyed by
# the line of the build call, as observed on the zig-hash-internals branch
# in the smoke run (traces/llm/bench/internals-smoke.md). When the C
# sources move, re-run the smoke and update @CENSUS; a site that no longer
# maps simply prints as function@file:line.
#
# Output: markdown. Per site, ordered by hash cycles: a table of op counts,
# cycles, cycles per op and the share of all hash cycles and of
# total_cycles, then the build-size and demolish (max items, by set and
# rung) histograms, nonzero buckets only. `grow` and `migrate` run inside
# the insert that triggered them, so their cycles are already in `insert`:
# they are listed but outside the shares. Files with no table at all
# (header only) are counted but add nothing to total_cycles or the shares.
# `## Hash share` ends the report: per program (the first *.moarvm in the
# command line, else the executable, with " -e" when -e was given) the
# hash cycles over the program's total_cycles. Probe rows, if a file has
# them, are ignored.
#
# --census adds the census sites that never appeared. --tsv writes the
# merged rows with the label in place of the site id.
use strict;
use warnings;
use File::Basename qw(basename);
use Getopt::Long;

# [label, file basename, function regex, first line, last line]; first match
# wins, rows with lines before the rows without.
my @CENSUS = (
    [ 'i1', 'moar.c', qr/^MVM_vm_create_instance$/, 182, 182 ],
    [ 'f1', 'moar.c', qr/^MVM_vm_create_instance$/, 186, 186 ],
    [ 'f2', 'moar.c', qr/^MVM_vm_create_instance$/, 187, 187 ],
    [ 'f3', 'moar.c', qr/^MVM_vm_create_instance$/, 191, 191 ],
    [ 'f4', 'moar.c', qr/^MVM_vm_create_instance$/, 195, 195 ],
    [ 'f5', 'moar.c', qr/^MVM_vm_create_instance$/, 199, 199 ],
    [ 's1', 'moar.c', qr/^MVM_vm_create_instance$/, 203, 203 ],
    [ 'f6', 'moar.c', qr/^MVM_vm_create_instance$/, 207, 207 ],
    [ 'f7', 'moar.c', qr/^MVM_vm_create_instance$/, 210, 210 ],
    [ 'p1', 'moar.c', qr/^MVM_vm_create_instance$/, 214, 214 ],
    [ 'i2', 'bytecode.c', qr/^(?:MVM_bytecode_finish_frame|deserialize_frames)$/, 667, 667 ],
    [ 's2', 'bytecode.c', qr/^(?:MVM_bytecode_finish_frame|deserialize_frames)$/, 777, 777 ],
    [ 'f8', 'syscall.c', qr/^(?:MVM_disp_syscall_setup|add_to_hash)$/ ],
    [ 's3', 'HashAttrStore.c', qr/copy_to$/ ],
    [ 's4', 'HashAttrStore.c', qr/bind_attribute$/ ],
    [ 's5', 'MVMHash.c', qr/bind_key$/ ],
    [ 's6', 'MVMHash.c', qr/^deserialize(?:\.\d+)?$/ ],
    [ 's9', 'MVMHash.c', qr/copy_to$/ ],
    [ 's7', 'nativecall_libffi.c', qr/./ ],
    [ 's8', 'nativecall_dyncall.c', qr/./ ],
    [ 'u1', 'unicode_ops.c', qr/^(?:generate_property_codes_by_names_aliases|MVM_unicode_name_to_property_code)$/ ],
    [ 'u2', 'unicode_ops.c', qr/^(?:generate_property_codes_by_seq_names|MVM_unicode_string_from_name)$/ ],
    [ 'u4', 'unicode_ops.c', qr/^MVM_unicode_init$/ ],
    [ 'u3', 'unicode_db.c', qr/^(?:generate_codepoints_by_name|MVM_unicode_lookup_by_name)$/ ],
    [ 'u3', 'unicode_ops.c', qr/^MVM_unicode_lookup_by_name$/ ],
    [ 'i3', 'MVMStaticFrame.c', qr/copy_to$/ ],
    [ 'p1', 'objectid.c', qr/^MVM_gc_object_id$/ ],
    [ 'p2', 'heapsnapshot.c', qr/./ ],
);
my @OPS = qw(build insert overwrite fetch_hit fetch_miss delete_hit delete_miss
             iter_start iter_step copy grow migrate demolish);
my %NESTED = (grow => 1, migrate => 1);    # inside insert's cycles
my @BUCKET = ('<=4', '<=16', '<=32', '<=64', '<=65', '<=128', '<=256', '<=1024', '<=16384', '>16384');

my ($lib, $census, $tsv_out);
GetOptions('lib=s' => \$lib, 'census' => \$census, 'tsv=s' => \$tsv_out)
    or die "usage: $0 DIR --lib=PATH/libmoar.so [--census] [--tsv=OUT.tsv]\n";
my $dir = shift @ARGV;
die "usage: $0 DIR --lib=PATH/libmoar.so [--census] [--tsv=OUT.tsv]\n" unless defined $dir && defined $lib;
my @files = sort glob("$dir/*.tsv");
die "$0: no *.tsv files in $dir\n" unless @files;

my %resolved;    # offset => [function, file:line]
sub a2l {
    my ($tool, $off) = @_;
    open my $p, '-|', $tool, '-e', $lib, '-f', '-C', sprintf('0x%x', $off) or return;
    my @l = map { chomp; $_ } <$p>;
    close $p;
    return @l[0, 1];
}
sub resolve {
    my ($off) = @_;
    return @{ $resolved{$off} } if $resolved{$off};
    my $at = $off > 0 ? $off - 1 : $off;    # the call, not the return address
    my ($f, $loc) = a2l('addr2line', $at);
    ($f, $loc) = a2l('llvm-addr2line', $at) if !defined $loc || $loc !~ /:[1-9]\d*$/;
    $f = '??' unless defined $f;
    $loc = '??:0' unless defined $loc;
    $loc =~ s/ \(discriminator \d+\)//;
    $loc =~ s{^.*?/(src/)}{$1};
    $f =~ s/\.(?:[A-Za-z_]+\.)*\d+$//;      # LTO clone suffix: deserialize.2546
    return @{ $resolved{$off} = [ $f, $loc ] };
}
sub label_of {
    my ($f, $loc) = @_;
    my ($path, $line) = $loc =~ /^(.*):(\d+|\?)$/ ? ($1, $2) : ($loc, 0);
    my $base = basename($path);
    for my $c (@CENSUS) {
        my ($label, $file, $re, $lo, $hi) = @$c;
        next unless $base eq $file && $f =~ $re;
        next if defined $lo && ($line !~ /^\d+$/ || $line < $lo || $line > $hi);
        return $label;
    }
    return undef;
}

my (%op, %build, %demolish, %where);    # keyed by site label
my ($nfiles, $nheader, $total_cycles, $hash_cycles) = (0, 0, 0, 0);
my %prog;                               # program => { files, header, total, hash }
for my $file (@files) {
    open my $fh, '<', $file or die "$file: $!";
    my (%head, %site, @rows);
    while (<$fh>) {
        chomp;
        if (/^# (\w+): ?(.*)$/) { $head{$1} = $2; next }
        push @rows, [ split /\t/ ] if length;
    }
    close $fh;
    $nfiles++;
    my $name;
    {
        my @tok = split ' ', $head{cmdline} // '';
        my ($mvm) = grep { /\.moarvm$/ } @tok;
        $name = defined $mvm ? basename($mvm) : @tok ? basename($tok[0]) : '?';
        $name .= ' -e' if grep { $_ eq '-e' } @tok;
    }
    my $p = $prog{$name} ||= { files => 0, header => 0, total => 0, hash => 0 };
    $p->{files}++;
    for (grep { $_->[0] eq 'site' } @rows) {
        my ($f, $loc) = resolve(hex $_->[2]);
        my $l = label_of($f, $loc);
        my $text = "$f\@$loc";
        $site{ $_->[1] } = defined $l ? [ $l, "$f ($loc)" ] : [ $text, $text ];
    }
    $site{255} = [ 'other', 'other' ];
    my $name_of = sub {
        my $s = $site{ $_[0] } or die "$file: row for unknown site $_[0]\n";
        $where{ $s->[0] } //= $s->[1];
        return $s->[0];
    };
    my $file_hash = 0;
    my $any = 0;
    for my $r (@rows) {
        my $kind = $r->[0];
        if ($kind eq 'op') {
            my ($s, $o, $n, $c) = @$r[ 1 .. 4 ];
            my $l = $name_of->($s);
            $op{$l}{$o}[0] += $n;
            $op{$l}{$o}[1] += $c;
            $file_hash += $c unless $NESTED{$o};
            $any = 1;
        } elsif ($kind eq 'build') {
            $build{ $name_of->($r->[1]) }[ $r->[2] ] += $r->[3];
            $any = 1;
        } elsif ($kind eq 'demolish') {
            $demolish{ $name_of->($r->[1]) }{"$r->[2]\t$r->[3]"}[ $r->[4] ] += $r->[5];
            $any = 1;
        }
    }
    if ($any) {
        $total_cycles += $head{total_cycles} // 0;
        $hash_cycles += $file_hash;
        $p->{total} += $head{total_cycles} // 0;
        $p->{hash} += $file_hash;
    } else {
        $nheader++;
        $p->{header}++;
    }
}

sub pct { my ($n, $d) = @_; return $d ? sprintf('%.1f', 100 * $n / $d) : '-' }
sub site_hash { my $l = shift; my $t = 0; $t += $op{$l}{$_}[1] for grep { !$NESTED{$_} } keys %{ $op{$l} || {} }; return $t }

my @labels = sort { site_hash($b) <=> site_hash($a) or $a cmp $b } keys %op;
for my $l (keys %build, keys %demolish) { push @labels, $l unless grep { $_ eq $l } @labels }

print "# Hash statistics\n\n";
print "Files: $nfiles ($nheader header-only)\n";
print "Hash cycles: $hash_cycles of $total_cycles (", pct($hash_cycles, $total_cycles), "%)\n\n";
print "## Sites\n\n";
for my $l (@labels) {
    my $w = $where{$l};
    my $mapped = $l =~ /^[a-z]\d$/;
    if ($mapped) {
        print "### $l $w\n\n";
    } else {
        print "### $l\n\n";
    }
    my $sh = site_hash($l);
    print "Site cycles: $sh (", pct($sh, $hash_cycles), "% of hash, ", pct($sh, $total_cycles), "% of total)\n\n";
    print "| op | count | cycles | cycles/op | % of hash | % of total |\n|---|---|---|---|---|---|\n";
    for my $o (@OPS) {
        my $e = $op{$l}{$o} or next;
        my ($n, $c) = @$e;
        my $per = sprintf('%.1f', $n ? $c / $n : 0);
        if ($NESTED{$o}) { print "| $o | $n | $c | $per | (in insert) | (in insert) |\n"; next }
        print "| $o | $n | $c | $per | ", pct($c, $hash_cycles), " | ", pct($c, $total_cycles), " |\n";
    }
    print "\n";
    if (my $b = $build{$l}) {
        print "- build: ", join(' ', map { "$BUCKET[$_]=$b->[$_]" } grep { $b->[$_] } 0 .. 9), "\n";
    }
    for my $k (sort keys %{ $demolish{$l} || {} }) {
        my ($set, $rung) = split /\t/, $k;
        my $d = $demolish{$l}{$k};
        print "- demolish set $set rung $rung: ", join(' ', map { "$BUCKET[$_]=$d->[$_]" } grep { $d->[$_] } 0 .. 9), "\n";
    }
    print "\n" if $build{$l} || $demolish{$l};
}

if ($census) {
    my %seen = map { $_ => 1 } @labels;
    my %all = map { $_->[0] => 1 } @CENSUS;
    my @missing = sort grep { !$seen{$_} } keys %all;
    print "## Census sites not seen\n\n", (@missing ? join(' ', @missing) : 'none'), "\n\n";
}

print "## Hash share\n\n| program | files | header-only | total cycles | hash cycles | % |\n|---|---|---|---|---|---|\n";
for my $n (sort keys %prog) {
    my $p = $prog{$n};
    print "| $n | $p->{files} | $p->{header} | $p->{total} | $p->{hash} | ", pct($p->{hash}, $p->{total}), " |\n";
}

if ($tsv_out) {
    open my $o, '>', $tsv_out or die "$tsv_out: $!";
    for my $l (sort keys %op) {
        for my $n (@OPS) { my $e = $op{$l}{$n} or next; print $o "op\t$l\t$n\t$e->[0]\t$e->[1]\n" }
    }
    for my $l (sort keys %build) {
        for my $i (0 .. 9) { print $o "build\t$l\t$i\t$build{$l}[$i]\n" if $build{$l}[$i] }
    }
    for my $l (sort keys %demolish) {
        for my $k (sort keys %{ $demolish{$l} }) {
            for my $i (0 .. 9) { print $o "demolish\t$l\t$k\t$i\t$demolish{$l}{$k}[$i]\n" if $demolish{$l}{$k}[$i] }
        }
    }
    close $o;
}
