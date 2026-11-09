# Three background (app-lifetime) threads: two allocate in loops, one mostly
# sleeps, so a GC run is likely in flight when the main thread returns.
sub alloc_loop() {
    while 1 {
        my @a := nqp::list();
        my $j := 0;
        while $j < 100 {
            nqp::push(@a, nqp::hash('k', ~$j));
            $j++;
        }
    }
}
my $t1 := nqp::newthread({ alloc_loop() }, 1);
my $t2 := nqp::newthread({ alloc_loop() }, 1);
my $t3 := nqp::newthread({
    while 1 {
        nqp::sleep(0.001);
        my @a := nqp::list();
        my $j := 0;
        while $j < 10 {
            nqp::push(@a, nqp::hash('k', ~$j));
            $j++;
        }
    }
}, 1);
nqp::threadrun($t1);
nqp::threadrun($t2);
nqp::threadrun($t3);
nqp::sleep(0.2);
say("main returning");
