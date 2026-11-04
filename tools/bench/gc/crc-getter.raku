#!/usr/bin/env raku
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

# Simulating the traffic from our eventual input, a partitioned Candycane™ queue
my $package-supplier = Supplier.new;
my $package-supply   = $package-supplier.Supply;
# A dummy sink that ignores the data and prints the processing duration of the CRC32 stage
my $output-supplier  = Supplier.new;
my $output-supply    = $output-supplier.Supply;
# Any address that fails the CRC32 test goes through here
my $bad-address-supplier = Supplier.new; 
my $bad-address-supply   = $bad-address-supplier.Supply;
# A tick begins processing a new batch
my $tick-supplier  = Supplier.new;
my $package-ticker = $tick-supplier.Supply;

my $time = now;
my $bad-address = $address.succ;

my @packages = $bad-packages
                ?? (Package.new xx ($volume - ($volume * 0.1)), Package.new(:address($bad-address)) xx ($volume * 0.1)).flat
                !! Package.new xx $volume;
note ">>> INIT: {now - $time}s ($volume objects)";

$package-ticker.act({
    $package-supplier.emit(@packages);
});

$package-supply.act(-> @items {
    my $time = now;
    @items.map( -> $item {
        if $item.crc32 != String::CRC32::crc32($item.address) {
            $bad-address-supplier.emit($item);
        }
    });
    $output-supplier.emit([@items, now - $time]);
});

my $count = 0;
my $bad-count = 0;
# Start the train (after waiting for the react block to spin up)
start { sleep 0.001; $tick-supplier.emit(True); }
react {
    whenever $output-supply -> [@itmes, $duration] {
        say "RUN {++$count}: {$duration}s";
        if $count == $runs {
            note "<<< $bad-count packages with bad addresses found. Alert the Elves!" if $bad-packages;
            done();
        }
        $tick-supplier.emit(True);
    }

    whenever $bad-address-supply -> $item {
        $bad-count++;
        # ... send to remediation queue and alert the elves!
    }
}