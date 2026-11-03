# Tests of nqp::hashstrategy and nqp::hashseal (the hash layout bake-off ops).
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

# A strategy 3 hash (unsealed) holding k0..k<n-1> => 0..n-1.
sub strategy3(int $n) {
    my %h := nqp::hash();
    nqp::hashstrategy(%h, 3, 0);
    my int $i := 0;
    while $i < $n { %h{"k$i"} := $i; $i := $i + 1 }
    %h
}

# Whether k<from>..k<to-1> fetch their values.
sub all_there(%h, int $from, int $to) {
    my int $bad := 0;
    my int $i := $from;
    while $i < $to { $bad := $bad + 1 unless nqp::atkey(%h, "k$i") == $i; $i := $i + 1 }
    $bad == 0
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
    $msg := dies({ nqp::hashseal(nqp::list()) });
    ok(contains($msg, 'concrete hash'), "hashseal on a list dies ($msg)");
}

{
    my %h := nqp::hash();
    my $msg := dies({ nqp::hashstrategy(%h, 9, 0) });
    ok(contains($msg, 'hash strategy 9'), "unknown strategy 9 dies ($msg)");
}

{
    my %h := nqp::hash('x', 10, 'y', 20);
    my $r := nqp::hashseal(%h);
    ok(nqp::eqaddr($r, %h), 'hashseal returns the hash');
    ok(nqp::elems(%h) == 2 && nqp::atkey(%h, 'x') == 10 && nqp::atkey(%h, 'y') == 20,
        'hashseal leaves the contents unchanged');
    $r := nqp::hashseal(%h);
    ok(nqp::eqaddr($r, %h) && nqp::elems(%h) == 2, 'hashseal twice is fine');
    my %e := nqp::hash();
    ok(nqp::eqaddr(nqp::hashseal(%e), %e) && nqp::elems(%e) == 0, 'hashseal on an unbuilt hash is fine');
}

# Strategies 1 (the Swiss-style tier), 2 (the array-ordered tier) and 3
# (the fixed-key tier; unsealed, a staging Robin Hood table).
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

# Strategy 3 sealed: nqp::hashseal rebuilds the table as the fixed-key
# layout; the first insert after it migrates to Robin Hood.
{
    my %h := strategy3(4);
    my $r := nqp::hashseal(%h);
    ok(nqp::eqaddr($r, %h), 'hashseal of a strategy 3 hash returns the hash');
    ok(nqp::elems(%h) == 4 && all_there(%h, 0, 4) && !nqp::existskey(%h, 'k4'),
        'strategy 3 sealed: every key fetches, an absent one misses');
    nqp::deletekey(%h, 'k1');
    ok(nqp::elems(%h) == 3 && !nqp::existskey(%h, 'k1') && nqp::atkey(%h, 'k2') == 2,
        'strategy 3 sealed: delete');
    my int $n := 0;
    for %h { $n := $n + 1 }
    ok($n == 3, 'strategy 3 sealed: iteration sees 3 entries');
}

{
    my %h := strategy3(100);
    nqp::hashseal(%h);
    %h<new> := 'x';
    ok(nqp::elems(%h) == 101 && nqp::atkey(%h, 'new') eq 'x' && all_there(%h, 0, 100),
        'strategy 3: insert after seal keeps every entry');
    my int $i := 0;
    while $i < 1000 { %h{"m$i"} := $i; $i := $i + 1 }
    ok(nqp::elems(%h) == 1101 && all_there(%h, 0, 100) && nqp::atkey(%h, 'm999') == 999,
        'strategy 3: the migrated table keeps growing');
    nqp::hashseal(%h);
    ok(nqp::elems(%h) == 1101 && all_there(%h, 0, 100), 'strategy 3: seal after the migration is a no-op');
}

{
    my %h := strategy3(50);
    nqp::hashseal(%h);
    my $r := nqp::hashseal(%h);
    ok(nqp::eqaddr($r, %h) && nqp::elems(%h) == 50 && all_there(%h, 0, 50),
        'strategy 3: hashseal twice is fine');
    my %e := nqp::hash();
    nqp::hashstrategy(%e, 3, 0);
    nqp::hashseal(%e);
    ok(nqp::elems(%e) == 0 && !nqp::existskey(%e, 'a'), 'strategy 3: an empty hash seals');
    %e<a> := 1;
    ok(nqp::elems(%e) == 1 && nqp::atkey(%e, 'a') == 1, 'strategy 3: insert into an empty sealed hash');
}

{
    my %h := strategy3(100);
    nqp::hashseal(%h);
    nqp::deletekey(%h, 'k0');
    my %c := nqp::clone(%h);
    ok(nqp::elems(%c) == 99 && all_there(%c, 1, 100) && !nqp::existskey(%c, 'k0'),
        'strategy 3: nqp::clone of a sealed hash keeps the contents');
    %c<new> := 1;
    nqp::deletekey(%c, 'k1');
    ok(nqp::elems(%h) == 99 && !nqp::existskey(%h, 'new') && nqp::existskey(%h, 'k1'),
        'strategy 3: the sealed original is independent of the clone');
    %h<other> := 2;
    ok(nqp::elems(%c) == 99 && !nqp::existskey(%c, 'other') && nqp::existskey(%c, 'new'),
        'strategy 3: the clone is independent of the original');
}

{
    my %h := strategy3(500);
    nqp::hashseal(%h);
    my int $visits := 0;
    my int $sum := 0;
    for %h { $visits := $visits + 1; $sum := $sum + nqp::iterval($_); nqp::deletekey(%h, nqp::iterkey_s($_)) }
    ok($visits == 500 && $sum == 500 * 499 / 2 && nqp::elems(%h) == 0,
        "strategy 3 sealed: deleting each entry as it is visited visits all ($visits)");
}

for nqp::list(4) -> $s {
    my %h := nqp::hash();
    my $msg := dies({ nqp::hashstrategy(%h, $s, 0) });
    ok(contains($msg, 'not available'), "strategy $s is not available ($msg)");
}

say("1..$test");
nqp::exit(1) if $failed;
