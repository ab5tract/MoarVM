//! Zig port of src/platform/posix/time.c (linux). Same symbols, same
//! behaviour; libc is reached through the translated header so this file
//! has no dependency on std.posix.
const moar = @import("moar");
const c = moar.c;

const E9: u64 = 1_000_000_000;

/// Wall-clock nanoseconds since the epoch; 0 if the clock cannot be read.
export fn MVM_platform_now() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_REALTIME, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * E9 + @as(u64, @intCast(ts.tv_nsec));
}

fn sleepLoop(timeout: *c.struct_timespec) void {
    // nanosleep writes the remaining time into its second argument when
    // interrupted, so retrying with the same struct resumes the sleep.
    while (c.nanosleep(timeout, timeout) != 0 and c.__errno_location().* == c.EINTR) {}
}

export fn MVM_platform_sleep(second: f64) void {
    var timeout: c.struct_timespec = undefined;
    timeout.tv_sec = @trunc(second);
    // C: (long)((second - timeout.tv_sec) * E9F); the float literal is
    // promoted to double, so the whole expression is double precision.
    const whole: f64 = @floatFromInt(timeout.tv_sec);
    timeout.tv_nsec = @trunc((second - whole) * 1_000_000_000.0);
    sleepLoop(&timeout);
}

export fn MVM_platform_nanosleep(nanos: u64) void {
    var timeout: c.struct_timespec = undefined;
    timeout.tv_sec = @intCast(nanos / E9);
    timeout.tv_nsec = @intCast(nanos % E9);
    sleepLoop(&timeout);
}

export fn MVM_platform_decodelocaltime(tc: *moar.ThreadContext, time: i64, decoded: [*]i64) void {
    const t: c.time_t = @intCast(time);
    var tm: c.struct_tm = undefined;
    if (c.localtime_r(&t, &tm) == null)
        c.MVM_exception_throw_adhoc(tc, "Could not decode localtime: %s", c.strerror(c.__errno_location().*));
    decoded[0] = tm.tm_sec;
    decoded[1] = tm.tm_min;
    decoded[2] = tm.tm_hour;
    decoded[3] = tm.tm_mday;
    decoded[4] = tm.tm_mon + 1;
    decoded[5] = tm.tm_year + 1900;
    decoded[6] = tm.tm_wday;
    decoded[7] = tm.tm_yday;
    decoded[8] = tm.tm_isdst;
}
