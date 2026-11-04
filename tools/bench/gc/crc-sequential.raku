#!/usr/bin/env raku
# Sequential reduction of crc-getter.raku (the user's program, beside this
# file) for the GC oracle: the same Package class, the same @packages
# construction (`xx $volume`, and with --bad-packages the 90/10 split), the
# same per-batch map of crc32 checks and the same $bad-count; the supplies,
# `react` and `start` are gone, so every batch runs on the main thread.
# One `RUN $n: <duration>s` line per batch; exit 0.
# One change beyond the removals, for a repeatable GC log: durations are
# `now.Num - $time.Num` (a Num) instead of `now - $time` (a Duration, a Rat),
# whose allocation varies with the clock value (traces/llm/bench/
# gc-oracle-repeatability.md); `now` itself is still taken as in the original.
# Usage: RAKULIB=tools/bench/gc/lib raku tools/bench/gc/crc-sequential.raku
#            [--volume=N (default 100)] [--runs=K (default 5)] [--bad-packages]
use v6.*;

unit sub MAIN(:$runs = 5, :$volume = 100, :$bad-packages = False);

use String::CRC32;
use NativeCall;

my $address = "01101011 Hyper Drive";
my $crc32 = String::CRC32::crc32($address);
class Package {
    has Str $.address is rw = $address;
    has uint32 $.crc32 = $crc32;
}

my $time = now;
my $bad-address = $address.succ;

my @packages = $bad-packages
                ?? (Package.new xx ($volume - ($volume * 0.1)), Package.new(:address($bad-address)) xx ($volume * 0.1)).flat
                !! Package.new xx $volume;
note ">>> INIT: {now.Num - $time.Num}s ($volume objects)";

my $count = 0;
my $bad-count = 0;
while $count < $runs {
    my @items := @packages;
    my $time = now;
    @items.map( -> $item {
        if $item.crc32 != String::CRC32::crc32($item.address) {
            $bad-count++;
        }
    });
    my $duration = now.Num - $time.Num;
    say "RUN {++$count}: {$duration}s";
}
note "<<< $bad-count packages with bad addresses found. Alert the Elves!" if $bad-packages;
