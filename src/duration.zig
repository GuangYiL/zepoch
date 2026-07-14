//! 有符号、纳秒精度的时间间隔。
//! Signed time spans with nanosecond precision.

const std = @import("std");

const nanoseconds_per_microsecond: i128 = 1_000;
const nanoseconds_per_millisecond: i128 = 1_000_000;
const nanoseconds_per_second: i128 = 1_000_000_000;
const nanoseconds_per_minute: i128 = 60 * nanoseconds_per_second;
const nanoseconds_per_hour: i128 = 60 * nanoseconds_per_minute;

pub const Duration = struct {
    nanoseconds: i128,

    pub const zero: Duration = .{ .nanoseconds = 0 };

    pub fn fromNanoseconds(nanoseconds: i128) Duration {
        return .{ .nanoseconds = nanoseconds };
    }

    pub fn fromMicroseconds(microseconds: i64) Duration {
        return .{
            .nanoseconds = @as(i128, microseconds) *
                nanoseconds_per_microsecond,
        };
    }

    pub fn fromMilliseconds(milliseconds: i64) Duration {
        return .{
            .nanoseconds = @as(i128, milliseconds) *
                nanoseconds_per_millisecond,
        };
    }

    pub fn fromSeconds(seconds: i64) Duration {
        return .{
            .nanoseconds = @as(i128, seconds) * nanoseconds_per_second,
        };
    }

    pub fn fromMinutes(minutes: i64) Duration {
        return .{
            .nanoseconds = @as(i128, minutes) * nanoseconds_per_minute,
        };
    }

    pub fn fromHours(hours: i64) Duration {
        return .{
            .nanoseconds = @as(i128, hours) * nanoseconds_per_hour,
        };
    }

    pub fn add(
        duration: Duration,
        other: Duration,
    ) error{Overflow}!Duration {
        return .{
            .nanoseconds = try std.math.add(
                i128,
                duration.nanoseconds,
                other.nanoseconds,
            ),
        };
    }

    pub fn subtract(
        duration: Duration,
        other: Duration,
    ) error{Overflow}!Duration {
        return .{
            .nanoseconds = try std.math.sub(
                i128,
                duration.nanoseconds,
                other.nanoseconds,
            ),
        };
    }

    pub fn negate(duration: Duration) error{Overflow}!Duration {
        return .{
            .nanoseconds = try std.math.negate(duration.nanoseconds),
        };
    }

    pub fn order(duration: Duration, other: Duration) std.math.Order {
        return std.math.order(duration.nanoseconds, other.nanoseconds);
    }
};

const testing = std.testing;

test "Duration constructors preserve exact units" {
    try testing.expectEqual(
        @as(i128, 1_500_000_000),
        Duration.fromMilliseconds(1_500).nanoseconds,
    );
    try testing.expectEqual(
        @as(i128, 86_400_000_000_000),
        Duration.fromHours(24).nanoseconds,
    );
}

test "Duration arithmetic reports i128 overflow" {
    const maximum = Duration.fromNanoseconds(std.math.maxInt(i128));
    try testing.expectError(
        error.Overflow,
        maximum.add(Duration.fromNanoseconds(1)),
    );
    try testing.expectError(
        error.Overflow,
        Duration.fromNanoseconds(std.math.minInt(i128)).negate(),
    );
}

test "Duration order compares signed intervals" {
    try testing.expectEqual(
        std.math.Order.lt,
        Duration.fromSeconds(-1).order(Duration.zero),
    );
}
