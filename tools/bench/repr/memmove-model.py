#!/usr/bin/env python3
# memmove-model.py PROGRAM OUTPUT NAME...: check that the lines NAME... of a
# differential program's OUTPUT print what asplice gives when its last copy
# has memmove semantics. diff.sh runs it on the head's output for the lines
# where head and base differ and that undefined-lines.txt lists, so that its
# exit 3 means "differs only where memmove was expected, and equals memmove".
#
# The model is the one of traces/llm/bench/va-differential-raw/selfsplice.py
# (which derived the diff-nqp entries of undefined-lines.txt), copied here so
# the instrument does not depend on the records, with two changes: it starts
# from given slots (so a splice can follow another), and it renders a whole
# output line as vmarray-diff.nqp's d() prints it, the SHA-1 form above 40
# elements included. It covers
#   diff-nqp <kind>.selfsplice.<case>  the cases of selfsp() in vmarray-diff.nqp
#   diff-nqp <kind>.selfsplice.twice   splice($a, $a, 2, 1) then splice($a, $a, 3, 0)
#                                      on fill($k, 4)
#   diff-raku <type>.nqp.splice.self   nqp::splice($a, $a, 3, 0) on the six values
#   diff-raku <type>.splice.self       of the type's section of vmarray-diff.raku
#                                      (0..5 for the int types, 0.5..5.5 for
#                                      num32/num64, 1..6 for the Buf/Blob types)
#   diff-raku array.reified.splice     nqp::splice(b, nqp::list(7, 8), 1, 2), then
#                                      nqp::splice(b, b, 2, 0), on an Array's
#                                      reified buffer of 1 2 3 4 5
# and nothing else: any other NAME is reported as "accepted without a model
# check", by name (no line undefined-lines.txt lists is left so).
#
# Prints one line per NAME ("memmove: NAME", "MISMATCH: NAME" with the
# expected and printed values, "accepted without a model check: NAME") and
# exits 0 when no covered NAME mismatches, 1 otherwise, 64 on misuse. A case
# name printed twice in OUTPUT, or given twice as a NAME, is misuse (64): the
# check would otherwise compare against whichever line came last.
import hashlib, re, sys


def ival(j, bits, signed):
    v = j * 3 + 1
    if bits == 0:
        return v
    v &= (1 << bits) - 1
    if signed and v >= 1 << (bits - 1):
        v -= 1 << bits
    return v


# How vmarray-diff.nqp's psh($k, $a, $j) fills and g() prints a kind
# (selfsplice.py's table: u64 prints through atpos_i, hence signed).
KINDS = {'obj': None, 'str': None, 'i64': (64, 1), 'i32': (32, 1), 'i16': (16, 1), 'i8': (8, 1),
         'u64': (64, 1), 'u32': (32, 0), 'u16': (16, 0), 'u8': (8, 0), 'n64': 'n', 'n32': 'n'}


def val(kind, j):
    k = KINDS[kind]
    if kind == 'obj':
        return 'o%d' % j
    if kind == 'str':
        return 's%d' % j
    if k == 'n':
        return '%g' % (j + 0.25)
    return str(ival(j, k[0], k[1]))


def unique(pairs, what):
    """A dict of `pairs`, refusing a key given twice (a dict literal would
    keep the last silently)."""
    d = {}
    for k, v in pairs:
        if k in d:
            raise SystemExit('memmove-model.py: %s %s given twice' % (what, k))
        d[k] = v
    return d


# selfsp($name, $len, $extra, $off, $cnt) of vmarray-diff.nqp.
CASES = unique([
    ('prepend', (10, 0, 0, 0)), ('append', (10, 0, 10, 0)), ('middle', (10, 0, 5, 0)),
    ('middle1', (10, 0, 1, 0)), ('middle9', (10, 0, 9, 0)), ('replace.2.3', (10, 0, 2, 3)),
    ('replace.0.3', (10, 0, 0, 3)), ('replace.all', (10, 0, 0, 10)), ('replace.over', (10, 0, 0, 20)),
    ('replace.tail', (10, 0, 7, 3)), ('replace.5.5', (10, 0, 5, 5)), ('replace.1.9', (10, 0, 1, 9)),
    ('replace.1.20', (10, 0, 1, 20)), ('neg', (10, 0, -3, 1)), ('past', (10, 0, 12, 0)),
    ('shifted.prepend', (10, 4, 0, 0)), ('shifted.prepend20', (10, 20, 0, 0)),
    ('shifted.middle', (10, 4, 5, 0)), ('shifted.replace', (10, 4, 0, 4)),
    ('shifted.replace.2.3', (10, 4, 2, 3)), ('shifted.append', (10, 4, 10, 0)), ('one', (1, 0, 0, 0)),
    ('one.replace', (1, 0, 0, 1)), ('empty', (0, 0, 0, 0)), ('big.middle', (9000, 0, 4500, 0)),
    ('big.1', (9000, 0, 1, 0)), ('big.replace', (9000, 0, 100, 5000)), ('big.shifted', (9000, 50, 3, 7)),
], 'case')


def splice(kind, slots, start, offset, count):
    """asplice($a, $a, offset, count) on storage `slots` whose live window
    starts at `start` and runs to the end of the list, memmove as the last
    copy (selfsplice.py's model with forward=False). Returns the storage and
    the new start; the live window again runs to the end of the list."""
    zero = {'obj': '<null>', 'str': '<null>'}.get(kind, '0')
    slots = list(slots)
    n = len(slots) - start
    elems0, elems1 = n, n
    if offset < 0:
        offset += elems0
    if offset == 0:
        d = elems1 - count
        if d > start:
            d = start
        if d <= -elems0:
            elems0 = 0
            count = 0
            start = 0
        elif d != 0:
            elems0 += d
            count += d
            start -= d
    if count == 0 and elems1 == 0:
        return slots[:start + elems0], start
    tail = max(elems0 - offset - count, 0)
    need = start + offset + elems1 + tail
    if tail > 0 and count > elems1:
        slots[start + offset + elems1:start + offset + elems1 + tail] = slots[start + offset + count:start + offset + count + tail]
    new = offset + elems1 + tail
    if new < elems0:  # set_size_internal clears what it gives up
        for i in range(start + new, start + elems0):
            slots[i] = zero
    slots += [zero] * max(0, need - len(slots))
    if tail > 0 and count < elems1:
        src = slots[start + offset + count:start + offset + count + tail]
        slots[start + offset + elems1:start + offset + elems1 + tail] = src
    src = slots[start:start + elems1]
    slots[start + offset:start + offset + elems1] = src
    return slots[:start + new], start


def rendered(v):
    """The text d($k, $a) prints for elements v."""
    if len(v) <= 40:
        return 'elems=%d [%s]' % (len(v), ' '.join(v))
    sha = hashlib.sha1(' '.join(v).encode()).hexdigest().upper()
    return 'elems=%d sha1=%s head=[%s] tail=[%s]' % (len(v), sha, ' '.join(v[:3]), ' '.join(v[-3:]))


# The diff-raku self-splices: the six values each type's section of
# vmarray-diff.raku starts from (fresh(^6), fresh(@v), fresh(1, 2, 3, 4, 5,
# 6)), as d() prints them, and the case names that splice them with
# nqp::splice($a, $a, 3, 0).
RAKU_INTS = ['int8', 'int16', 'int32', 'int64', 'uint8', 'uint16', 'uint32', 'uint64']
RAKU_BUFS = ['%s[uint%d]' % (t, b) for t in ('Buf', 'Blob') for b in (8, 16, 32, 64)]
RAKU_SIX = unique([('%s.nqp.splice.self' % t, [str(j) for j in range(6)]) for t in RAKU_INTS]
                  + [('%s.splice.self' % t, ['%g' % (j + 0.5) for j in range(6)]) for t in ('num32', 'num64')]
                  + [('%s.splice.self' % t, [str(j + 1) for j in range(6)]) for t in RAKU_BUFS], 'diff-raku case')


def expected_raku(name):
    """The memmove model's line for a diff-raku `name`, or None."""
    if name in RAKU_SIX:
        slots, start = splice('i64', RAKU_SIX[name], 0, 3, 0)
        return rendered(slots[start:])
    if name == 'array.reified.splice':
        # The first splice takes its elements from another list, so its
        # result is defined: 1 2 3 4 5 with 2 3 replaced by 7 8. The second
        # is the self-splice. od() prints the same 'elems=N [...]' as d().
        v = ['1', '2', '3', '4', '5']
        v = v[:1] + ['7', '8'] + v[3:]
        slots, start = splice('obj', v, 0, 2, 0)
        return rendered(slots[start:])
    return None


def expected(program, name):
    """The memmove model's line for `name`, or None when it covers none."""
    if program == 'diff-raku':
        return expected_raku(name)
    if program != 'diff-nqp':
        return None
    m = re.fullmatch(r'(\w+)\.selfsplice\.([\w.]+)', name)
    if not m or m.group(1) not in KINDS:
        return None
    kind, case = m.groups()
    if case == 'twice':
        slots, start = [val(kind, j) for j in range(4)], 0
        slots, start = splice(kind, slots, start, 2, 1)
        slots, start = splice(kind, slots, start, 3, 0)
        return rendered(slots[start:])
    if case not in CASES:
        return None
    n, extra, offset, count = CASES[case]
    # fill_shifted: `extra` values 90.. pushed first and shifted off again.
    slots = [val(kind, 90 + j) for j in range(extra)] + [val(kind, j) for j in range(n)]
    slots, start = splice(kind, slots, extra, offset, count)
    return rendered(slots[start:])


def main(argv):
    if len(argv) < 3:
        print('usage: memmove-model.py PROGRAM OUTPUT NAME...', file=sys.stderr)
        return 64
    program, output, names = argv[0], argv[1], argv[2:]
    printed = {}
    for line in open(output, encoding='utf-8', errors='surrogateescape'):
        line = line.rstrip('\n')
        i = line.find(': ')
        if i > 0:
            if line[:i] in printed:
                print('memmove-model.py: %s prints the case %s twice' % (output, line[:i]), file=sys.stderr)
                return 64
            printed[line[:i]] = line[i + 2:]
    if len(set(names)) != len(names):
        twice = sorted(n for n in set(names) if names.count(n) > 1)
        print('memmove-model.py: NAME given twice: %s' % ' '.join(twice), file=sys.stderr)
        return 64
    bad = 0
    for name in names:
        want = expected(program, name)
        if want is None:
            print('accepted without a model check: %s %s' % (program, name))
        elif printed.get(name) == want:
            print('memmove: %s %s' % (program, name))
        else:
            bad = 1
            print('MISMATCH: %s %s\n    memmove model: %s\n    printed:       %s' % (program, name, want, printed.get(name, '<no such line>')))
    return bad


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
