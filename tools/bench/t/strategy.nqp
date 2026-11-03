# Tests of nqp::hashstrategy (the hash layout strategy op).
# Prints TAP; exits non-zero on any failure. Needs an nqp that maps the ops:
#   <prefix>/bin/nqp-m tools/bench/t/strategy.nqp
# or `zig build strategy-test -Dnqp-prefix=<prefix>`.

my int $test := 0;
my int $failed := 0;

sub ok($cond, $desc) {
    $test := $test + 1;
    if $cond {
        say("ok $test - $desc");
    }
    else {
        say("not ok $test - $desc");
        $failed := $failed + 1;
    }
    $cond
}

# Runs &code; returns the exception message, or '' if it did not die.
sub dies(&code) {
    my $msg := '';
    try {
        code();
        CATCH { $msg := nqp::getmessage($!); $msg := '(no message)' unless $msg; }
    }
    $msg
}

sub contains($haystack, $needle) {
    nqp::index($haystack, $needle) >= 0
}

# bind 3 keys, check each exists, elems 3, delete one, elems 2, iterate counts 2.
sub round_trip(%h, $desc) {
    %h<alpha> := 1;
    %h<beta> := 2;
    %h<gamma> := 3;
    ok(nqp::existskey(%h, 'alpha') && nqp::existskey(%h, 'beta')
        && nqp::existskey(%h, 'gamma'), "$desc: bound keys exist");
    ok(nqp::elems(%h) == 3, "$desc: elems is 3");
    nqp::deletekey(%h, 'beta');
    ok(nqp::elems(%h) == 2 && !nqp::existskey(%h, 'beta'), "$desc: elems is 2 after a delete");
    my int $n := 0;
    for %h { $n := $n + 1 }
    ok($n == 2, "$desc: iteration sees 2 entries");
}

{
    my %h := nqp::hash();
    my $r := nqp::hashstrategy(%h, 0, 0);
    ok(nqp::eqaddr($r, %h), 'hashstrategy returns the hash');
    round_trip(%h, 'strategy 0, fresh hash');
}

{
    my %h := nqp::hash();
    nqp::hashstrategy(%h, 0, 1000);
    round_trip(%h, 'strategy 0, size hint 1000');
}

{
    my %h := nqp::hash('a', 1);
    my $msg := dies({ nqp::hashstrategy(%h, 0, 0) });
    ok(contains($msg, 'non-empty'), "hashstrategy on a non-empty hash dies ($msg)");
    ok(nqp::elems(%h) == 1 && nqp::atkey(%h, 'a') == 1, 'the non-empty hash is unchanged');
}

{
    my %h := nqp::hash('a', 1, 'b', 2);
    nqp::deletekey(%h, 'a');
    nqp::deletekey(%h, 'b');
    my $msg := dies({ nqp::hashstrategy(%h, 0, 8) });
    ok($msg eq '', "hashstrategy on a built but emptied hash succeeds ($msg)");
    round_trip(%h, 'strategy 0, after fill then delete all');
}

{
    my $msg := dies({ nqp::hashstrategy(42, 0, 0) });
    ok(contains($msg, 'concrete hash'), "hashstrategy on an int dies ($msg)");
    $msg := dies({ nqp::hashstrategy(nqp::list(), 0, 0) });
    ok(contains($msg, 'concrete hash'), "hashstrategy on a list dies ($msg)");
}

{
    my %h := nqp::hash();
    my $msg := dies({ nqp::hashstrategy(%h, 9, 0) });
    ok(contains($msg, 'hash strategy 9'), "unknown strategy 9 dies ($msg)");
}

# Strategies 1 (the Swiss-style tier), 2 (the array-ordered tier) and 3
# (Small, then the Swiss-style tier from 65 entries).
for 1, 2, 3 -> $s {
    {
        my %h := nqp::hash();
        my $r := nqp::hashstrategy(%h, $s, 0);
        ok(nqp::eqaddr($r, %h), "hashstrategy $s returns the hash");
        round_trip(%h, "strategy $s, fresh hash");
    }

    {
        my %h := nqp::hash();
        nqp::hashstrategy(%h, $s, 1000);
        round_trip(%h, "strategy $s, size hint 1000");
    }

    {
        my %h := nqp::hash('a', 1, 'b', 2);
        nqp::deletekey(%h, 'a');
        nqp::deletekey(%h, 'b');
        my $msg := dies({ nqp::hashstrategy(%h, $s, 8) });
        ok($msg eq '', "hashstrategy $s on a built but emptied hash succeeds ($msg)");
        round_trip(%h, "strategy $s, after fill then delete all");
    }

    {
        # Enough keys to grow through several sizes, then churn.
        my %h := nqp::hash();
        nqp::hashstrategy(%h, $s, 0);
        my int $i := 0;
        while $i < 5000 { %h{"k$i"} := $i; $i := $i + 1 }
        ok(nqp::elems(%h) == 5000, "strategy $s: 5000 keys bound");
        my int $bad := 0;
        $i := 0;
        while $i < 5000 { $bad := $bad + 1 unless nqp::atkey(%h, "k$i") == $i; $i := $i + 1 }
        ok($bad == 0, "strategy $s: every key fetches its value");
        $i := 0;
        while $i < 5000 { nqp::deletekey(%h, "k$i") if $i % 2; $i := $i + 1 }
        ok(nqp::elems(%h) == 2500 && !nqp::existskey(%h, 'k1') && nqp::existskey(%h, 'k2'),
            "strategy $s: half deleted");
        my int $sum := 0;
        for %h { $sum := $sum + nqp::iterval($_) }
        ok($sum == 2500 * 4998 / 2, "strategy $s: iteration sees exactly the live entries");
        $i := 0;
        while $i < 20000 { %h{"c$i"} := $i; nqp::deletekey(%h, "c$i"); $i := $i + 1 }
        ok(nqp::elems(%h) == 2500 && nqp::atkey(%h, 'k4998') == 4998, "strategy $s: churn keeps the contents");
    }

    {
        my %h := nqp::hash();
        nqp::hashstrategy(%h, $s, 0);
        my int $i := 0;
        while $i < 100 { %h{"k$i"} := $i; $i := $i + 1 }
        nqp::deletekey(%h, 'k0');
        my %c := nqp::clone(%h);
        ok(nqp::elems(%c) == 99 && nqp::atkey(%c, 'k99') == 99 && !nqp::existskey(%c, 'k0'),
            "strategy $s: nqp::clone keeps the contents");
        %c<new> := 1;
        nqp::deletekey(%c, 'k1');
        %h<other> := 2;
        ok(nqp::elems(%h) == 100 && !nqp::existskey(%h, 'new') && nqp::existskey(%h, 'k1'),
            "strategy $s: the original is independent of the clone");
        ok(nqp::elems(%c) == 99 && !nqp::existskey(%c, 'other') && nqp::existskey(%c, 'new'),
            "strategy $s: the clone is independent of the original");
    }

    {
        # MVMIter's protocol: deleting the current entry while iterating
        # visits every entry once (swap-remove in strategy 2).
        my %h := nqp::hash();
        nqp::hashstrategy(%h, $s, 0);
        my int $i := 0;
        while $i < 500 { %h{"k$i"} := $i; $i := $i + 1 }
        my int $visits := 0;
        my int $sum := 0;
        for %h { $visits := $visits + 1; $sum := $sum + nqp::iterval($_); nqp::deletekey(%h, nqp::iterkey_s($_)) }
        ok($visits == 500 && $sum == 500 * 499 / 2 && nqp::elems(%h) == 0,
            "strategy $s: deleting each entry as it is visited visits all ($visits)");
    }
}

for nqp::list(4) -> $s {
    my %h := nqp::hash();
    my $msg := dies({ nqp::hashstrategy(%h, $s, 0) });
    ok(contains($msg, 'not available'), "strategy $s is not available ($msg)");
}

say("1..$test");
nqp::exit(1) if $failed;
