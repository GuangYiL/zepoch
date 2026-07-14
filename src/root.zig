//! 显式区分 POSIX 时间点、墙上时间、固定偏移视图与单调时钟。
//! Explicitly separates POSIX instants, wall time, fixed-offset views, and monotonic clocks.

const std = @import("std");

pub const calendar = @import("calendar.zig");
pub const clock = @import("clock.zig");
pub const duration = @import("duration.zig");
pub const format = @import("format.zig");
pub const instant = @import("instant.zig");
pub const monotonic = @import("monotonic.zig");
pub const offset_datetime = @import("offset_datetime.zig");
pub const parse = @import("parse.zig");
pub const timezone = @import("timezone.zig");

pub const AmbiguousInstants = timezone.AmbiguousInstants;
pub const Clock = clock.Clock;
pub const ClockDomain = clock.ClockDomain;
pub const Duration = duration.Duration;
pub const Instant = instant.Instant;
pub const LocalDateTime = calendar.LocalDateTime;
pub const LocalResolution = timezone.LocalResolution;
pub const MonotonicClock = monotonic.MonotonicClock;
pub const MonotonicInstant = monotonic.MonotonicInstant;
pub const MonthOverflowPolicy = calendar.MonthOverflowPolicy;
pub const OffsetDateTime = offset_datetime.OffsetDateTime;
pub const TzifZone = timezone.TzifZone;
pub const UtcOffset = timezone.UtcOffset;
pub const Weekday = calendar.Weekday;
pub const ZoneState = timezone.ZoneState;
pub const system_awake_clock = clock.system_awake_clock;
pub const system_boot_clock = clock.system_boot_clock;
pub const system_realtime_clock = clock.system_realtime_clock;

test {
    _ = calendar;
    _ = clock;
    _ = duration;
    _ = format;
    _ = instant;
    _ = monotonic;
    _ = offset_datetime;
    _ = parse;
    _ = timezone;
}

test "absolute, offset, wall, and monotonic time are distinct types" {
    const wall = LocalDateTime{
        .year = 2024,
        .month = 11,
        .day = 3,
        .hour = 1,
        .minute = 30,
    };
    const absolute = try Instant.fromUnixSeconds(1_730_613_600, 0);
    const offset = OffsetDateTime{ .instant = absolute, .offset = .utc };
    const monotonic_value = try MonotonicInstant.now(.{
        .domain = .awake,
        .read_nanoseconds = fixedMonotonicNanoseconds,
    });

    try std.testing.expectEqual(@as(u8, 30), wall.minute);
    try std.testing.expectEqual(absolute, offset.instant);
    try std.testing.expectEqual(MonotonicClock.awake, monotonic_value.clock);
}

fn fixedMonotonicNanoseconds(_: ?*anyopaque) clock.Error!i128 {
    return 1;
}

test "RFC 3339 parsing composes with exact duration arithmetic" {
    const start = try parse.rfc3339("2024-01-31T23:59:59.5+08:00");
    const finish = OffsetDateTime{
        .instant = try start.instant.add(Duration.fromMilliseconds(1_500)),
        .offset = start.offset,
    };
    const local = try finish.toLocal();
    try std.testing.expectEqual(@as(u8, 2), local.month);
    try std.testing.expectEqual(@as(u8, 1), local.day);
    try std.testing.expectEqual(@as(u8, 1), local.second);
}

test "RFC 3339 formatting and parsing round trip exactly" {
    const original = try parse.rfc3339("2024-05-06T07:08:09.123400+05:30");
    var buffer: [48]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try format.writeRfc3339(original, &writer);
    try std.testing.expectEqualStrings(
        "2024-05-06T07:08:09.1234+05:30",
        writer.buffered(),
    );
    try std.testing.expectEqual(original, try parse.rfc3339(writer.buffered()));
}
