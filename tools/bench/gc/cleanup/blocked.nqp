# A background (app-lifetime) thread that spends most of its time blocked
# in nqp::sleep (GC status UNABLE) and allocates a little between sleeps.
my $t := nqp::newthread({
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
nqp::threadrun($t);
nqp::sleep(0.2);
say("main returning");
