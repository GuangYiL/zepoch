//! POSIX/Unix 时间轴上的绝对时间点；闰秒不属于该时间尺度。
//! Absolute instants on the POSIX/Unix timeline; leap seconds are outside this time scale.

const std = @import("std");
const clock_module = @import("clock.zig");
const Clock = clock_module.Clock;
const Duration = @import("duration.zig").Duration;

const nanoseconds_per_second: i128 = 1_000_000_000;

pub const Instant = struct {
    unix_seconds: i64,
    nanosecond: u32,

    pub fn now(clock: Clock) (clock_module.Error || error{ ClockDomainMismatch, Overflow })!Instant {
        if (clock.domain != .realtime) return error.ClockDomainMismatch;
        return fromUnixNanoseconds(try clock.read());
    }

    pub fn fromUnixSeconds(
        unix_seconds: i64,
        nanosecond: u32,
    ) error{InvalidNanosecond}!Instant {
        if (nanosecond >= nanoseconds_per_second) {
            return error.InvalidNanosecond;
        }
        return .{
            .unix_seconds = unix_seconds,
            .nanosecond = nanosecond,
        };
    }

    pub fn fromUnixMilliseconds(milliseconds: i64) Instant {
        return .{
            .unix_seconds = @divFloor(milliseconds, 1_000),
            .nanosecond = @intCast(@mod(milliseconds, 1_000) * 1_000_000),
        };
    }

    pub fn fromUnixMicroseconds(microseconds: i64) Instant {
        return .{
            .unix_seconds = @divFloor(microseconds, 1_000_000),
            .nanosecond = @intCast(@mod(microseconds, 1_000_000) * 1_000),
        };
    }

    pub fn fromUnixNanoseconds(nanoseconds: i128) error{Overflow}!Instant {
        return .{
            .unix_seconds = std.math.cast(
                i64,
                @divFloor(nanoseconds, nanoseconds_per_second),
            ) orelse return error.Overflow,
            .nanosecond = @intCast(@mod(nanoseconds, nanoseconds_per_second)),
        };
    }

    pub fn unixMilliseconds(instant: Instant) error{Overflow}!i64 {
        return std.math.cast(i64, @divFloor(instant.unixNanoseconds(), 1_000_000)) orelse
            error.Overflow;
    }

    pub fn unixMicroseconds(instant: Instant) error{Overflow}!i64 {
        return std.math.cast(i64, @divFloor(instant.unixNanoseconds(), 1_000)) orelse
            error.Overflow;
    }

    pub fn unixNanoseconds(instant: Instant) i128 {
        return @as(i128, instant.unix_seconds) * nanoseconds_per_second + instant.nanosecond;
    }

    pub fn add(instant: Instant, duration: Duration) error{Overflow}!Instant {
        return fromUnixNanoseconds(try std.math.add(
            i128,
            instant.unixNanoseconds(),
            duration.nanoseconds,
        ));
    }

    pub fn subtract(instant: Instant, duration: Duration) error{Overflow}!Instant {
        return fromUnixNanoseconds(try std.math.sub(
            i128,
            instant.unixNanoseconds(),
            duration.nanoseconds,
        ));
    }

    pub fn durationSince(instant: Instant, earlier: Instant) Duration {
        return Duration.fromNanoseconds(instant.unixNanoseconds() - earlier.unixNanoseconds());
    }

    pub fn order(instant: Instant, other: Instant) std.math.Order {
        const seconds_order = std.math.order(instant.unix_seconds, other.unix_seconds);
        if (seconds_order != .eq) return seconds_order;
        return std.math.order(instant.nanosecond, other.nanosecond);
    }
};

const testing = std.testing;

fn fixedRealtimeNanoseconds(_: ?*anyopaque) @import("clock.zig").Error!i128 {
    return -1;
}

test "Instant.now reads an explicit realtime clock" {
    const current = try Instant.now(.{
        .domain = .realtime,
        .read_nanoseconds = fixedRealtimeNanoseconds,
    });
    try testing.expectEqual(@as(i64, -1), current.unix_seconds);
    try testing.expectEqual(@as(u32, 999_999_999), current.nanosecond);
}

test "Instant.now rejects non-realtime clock domains" {
    try testing.expectError(error.ClockDomainMismatch, Instant.now(.{
        .domain = .awake,
        .read_nanoseconds = fixedRealtimeNanoseconds,
    }));
}

test "Instant rejects invalid nanoseconds" {
    try testing.expectError(
        error.InvalidNanosecond,
        Instant.fromUnixSeconds(0, 1_000_000_000),
    );
}

test "Instant converts negative Unix units with floor semantics" {
    const milliseconds = Instant.fromUnixMilliseconds(-500);
    try testing.expectEqual(@as(i64, -1), milliseconds.unix_seconds);
    try testing.expectEqual(@as(u32, 500_000_000), milliseconds.nanosecond);
    try testing.expectEqual(@as(i64, -500), try milliseconds.unixMilliseconds());

    const nanoseconds = try Instant.fromUnixNanoseconds(-1);
    try testing.expectEqual(@as(i128, -1), nanoseconds.unixNanoseconds());
}

test "Instant arithmetic preserves exact nanoseconds" {
    const start = try Instant.fromUnixSeconds(10, 750_000_000);
    const finish = try start.add(Duration.fromMilliseconds(500));

    try testing.expectEqual(@as(i64, 11), finish.unix_seconds);
    try testing.expectEqual(@as(u32, 250_000_000), finish.nanosecond);
    try testing.expectEqual(@as(i128, 500_000_000), finish.durationSince(start).nanoseconds);
    try testing.expectEqual(start, try finish.subtract(Duration.fromMilliseconds(500)));
}

test "Instant reports timestamp range overflow" {
    const maximum = try Instant.fromUnixSeconds(std.math.maxInt(i64), 999_999_999);
    try testing.expectError(error.Overflow, maximum.add(Duration.fromNanoseconds(1)));
}

test "Instant supports the full signed i64 second range" {
    const minimum = try Instant.fromUnixSeconds(std.math.minInt(i64), 0);
    const maximum = try Instant.fromUnixSeconds(std.math.maxInt(i64), 999_999_999);
    try testing.expectEqual(std.math.Order.lt, minimum.order(maximum));
}
