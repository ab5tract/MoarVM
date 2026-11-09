# A background (app-lifetime) thread that keeps allocating, so it is in
# GC status NONE and hits GC safepoints, while the main thread returns.
my $t := nqp::newthread({
    while 1 {
        my @a := nqp::list();
        my $j := 0;
        while $j < 100 {
            nqp::push(@a, nqp::hash('k', ~$j));
            $j++;
        }
    }
}, 1);
nqp::threadrun($t);
nqp::sleep(0.2);
say("main returning");
