//! 仅用于间隔测量的单调时间点，不能转换为日历时间。
//! Monotonic instants for interval measurement only; they cannot become calendar time.

const std = @import("std");
const clock_module = @import("clock.zig");
const Clock = clock_module.Clock;
const Duration = @import("duration.zig").Duration;

pub const MonotonicClock = enum {
    awake,
    boot,
};

pub const MonotonicInstant = struct {
    clock: MonotonicClock,
    nanoseconds: i96,

    pub fn now(
        source: Clock,
    ) (clock_module.Error || error{ ClockDomainMismatch, Overflow })!MonotonicInstant {
        const clock: MonotonicClock = switch (source.domain) {
            .awake => .awake,
            .boot => .boot,
            .realtime => return error.ClockDomainMismatch,
        };
        return .{
            .clock = clock,
            .nanoseconds = std.math.cast(i96, try source.read()) orelse return error.Overflow,
        };
    }

    pub fn durationSince(
        instant: MonotonicInstant,
        earlier: MonotonicInstant,
    ) error{ClockMismatch}!Duration {
        if (instant.clock != earlier.clock) return error.ClockMismatch;
        return Duration.fromNanoseconds(@as(i128, instant.nanoseconds) - earlier.nanoseconds);
    }
};

const testing = std.testing;

fn fixedMonotonicNanoseconds(_: ?*anyopaque) clock_module.Error!i128 {
    return 123;
}

test "MonotonicInstant receives a clock capability explicitly" {
    const instant = try MonotonicInstant.now(.{
        .domain = .awake,
        .read_nanoseconds = fixedMonotonicNanoseconds,
    });
    try testing.expectEqual(MonotonicClock.awake, instant.clock);
    try testing.expectEqual(@as(i96, 123), instant.nanoseconds);
}

test "MonotonicInstant rejects realtime clocks" {
    try testing.expectError(error.ClockDomainMismatch, MonotonicInstant.now(.{
        .domain = .realtime,
        .read_nanoseconds = fixedMonotonicNanoseconds,
    }));
}

test "MonotonicInstant rejects comparisons across clock domains" {
    const awake = MonotonicInstant{ .clock = .awake, .nanoseconds = 1 };
    const boot = MonotonicInstant{ .clock = .boot, .nanoseconds = 2 };
    try testing.expectError(error.ClockMismatch, boot.durationSince(awake));
}
