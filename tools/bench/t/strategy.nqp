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

for 1, 2, 3 -> $s {
    my %h := nqp::hash();
    my $msg := dies({ nqp::hashstrategy(%h, $s, 0) });
    ok(contains($msg, 'not available'), "strategy $s is not available ($msg)");
}

say("1..$test");
nqp::exit(1) if $failed;
