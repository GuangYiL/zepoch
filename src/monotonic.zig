//! 仅用于间隔测量的单调时间点，不能转换为日历时间。
//! Monotonic instants for interval measurement only; they cannot become calendar time.

const std = @import("std");
const Duration = @import("duration.zig").Duration;

pub const MonotonicClock = enum {
    awake,
    boot,

    fn ioClock(clock: MonotonicClock) std.Io.Clock {
        return switch (clock) {
            .awake => .awake,
            .boot => .boot,
        };
    }
};

pub const MonotonicInstant = struct {
    clock: MonotonicClock,
    nanoseconds: i96,

    pub fn now(io: std.Io, clock: MonotonicClock) MonotonicInstant {
        return .{
            .clock = clock,
            .nanoseconds = std.Io.Clock.now(clock.ioClock(), io).nanoseconds,
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

test "MonotonicInstant receives I/O and clock intent explicitly" {
    const instant = MonotonicInstant.now(testing.io, .awake);
    try testing.expectEqual(MonotonicClock.awake, instant.clock);
}

test "MonotonicInstant rejects comparisons across clock domains" {
    const awake = MonotonicInstant{ .clock = .awake, .nanoseconds = 1 };
    const boot = MonotonicInstant{ .clock = .boot, .nanoseconds = 2 };
    try testing.expectError(error.ClockMismatch, boot.durationSince(awake));
}
