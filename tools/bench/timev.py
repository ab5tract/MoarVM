#!/usr/bin/env python3
# Taken unchanged from the hash campaigns' scratchpad (timev.py), where it
# stood in for GNU `time -v`, which this machine lacks. Usage:
# tools/bench/timev.py OUTFILE CMD... (see the docstring).
"""GNU `time -v` stand-in: runs argv[2:] with stdout/stderr inherited, writes
`Elapsed (wall clock) time`, `Maximum resident set size (kbytes)` (from
wait4's rusage, the same figure GNU time reports) and `Exit status` to the file argv[1]."""
import os, sys, time, subprocess
out = sys.argv[1]; cmd = sys.argv[2:]
t0 = time.monotonic()
p = subprocess.Popen(cmd)
_, status, ru = os.wait4(p.pid, 0)
wall = time.monotonic() - t0
code = os.waitstatus_to_exitcode(status)
m, s = divmod(wall, 60)
with open(out, 'w') as f:
    f.write(f"\tCommand being timed: \"{' '.join(cmd)}\"\n")
    f.write(f"\tUser time (seconds): {ru.ru_utime:.2f}\n\tSystem time (seconds): {ru.ru_stime:.2f}\n")
    f.write(f"\tElapsed (wall clock) time (h:mm:ss or m:ss): {int(m)}:{s:05.2f}\n")
    f.write(f"\tMaximum resident set size (kbytes): {ru.ru_maxrss}\n\tExit status: {code}\n")
sys.exit(code)
