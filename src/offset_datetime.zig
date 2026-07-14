//! 一个绝对时间点及其显式固定偏移视图。
//! An absolute instant paired with an explicit fixed-offset view.

const std = @import("std");
const calendar = @import("calendar.zig");
const Instant = @import("instant.zig").Instant;
const timezone = @import("timezone.zig");

const FromLocalError = error{Overflow} || calendar.ValidationError;
const ViewError = error{Overflow} || calendar.ConversionError;

pub const OffsetDateTime = struct {
    instant: Instant,
    offset: timezone.UtcOffset,

    pub fn fromLocal(
        wall_time: calendar.LocalDateTime,
        offset: timezone.UtcOffset,
    ) FromLocalError!OffsetDateTime {
        const local_seconds = try calendar.unixSecondsFromLocal(wall_time);
        return .{
            .instant = try Instant.fromUnixSeconds(
                try std.math.sub(i64, local_seconds, offset.seconds),
                wall_time.nanosecond,
            ),
            .offset = offset,
        };
    }

    pub fn toLocal(datetime: OffsetDateTime) ViewError!calendar.LocalDateTime {
        const local_seconds = try std.math.add(
            i64,
            datetime.instant.unix_seconds,
            datetime.offset.seconds,
        );
        var result = try calendar.localDateTimeFromUnix(local_seconds);
        result.nanosecond = datetime.instant.nanosecond;
        return result;
    }

    pub fn addCalendarMonths(
        datetime: OffsetDateTime,
        months: i64,
        policy: calendar.MonthOverflowPolicy,
    ) (FromLocalError || ViewError)!OffsetDateTime {
        const shifted = try (try datetime.toLocal()).addMonths(months, policy);
        return fromLocal(shifted, datetime.offset);
    }

    pub fn startOfDay(datetime: OffsetDateTime) (FromLocalError || ViewError)!OffsetDateTime {
        var wall_time = try datetime.toLocal();
        wall_time.hour = 0;
        wall_time.minute = 0;
        wall_time.second = 0;
        wall_time.nanosecond = 0;
        return fromLocal(wall_time, datetime.offset);
    }

    pub fn endOfDay(datetime: OffsetDateTime) (FromLocalError || ViewError)!OffsetDateTime {
        var wall_time = try datetime.toLocal();
        wall_time.hour = 23;
        wall_time.minute = 59;
        wall_time.second = 59;
        wall_time.nanosecond = 999_999_999;
        return fromLocal(wall_time, datetime.offset);
    }
};

const testing = std.testing;

test "offset changes the civil view without changing the instant" {
    const instant = try Instant.fromUnixSeconds(1_000_000_000, 500);
    const shanghai = OffsetDateTime{
        .instant = instant,
        .offset = try timezone.UtcOffset.fromSeconds(8 * 3_600),
    };

    try testing.expectEqual(instant, shanghai.instant);
    try testing.expectEqual(@as(u8, 9), (try shanghai.toLocal()).hour);
}

test "calendar month arithmetic requires a policy" {
    const january = try OffsetDateTime.fromLocal(.{
        .year = 2024,
        .month = 1,
        .day = 31,
    }, .utc);
    try testing.expectError(
        error.InvalidDay,
        january.addCalendarMonths(1, .reject),
    );
    const february = try january.addCalendarMonths(1, .clamp);
    try testing.expectEqual(@as(u8, 29), (try february.toLocal()).day);
}

test "day boundaries preserve fixed offsets and set nanoseconds" {
    const datetime = try OffsetDateTime.fromLocal(.{
        .year = 2024,
        .month = 1,
        .day = 15,
        .hour = 12,
    }, try timezone.UtcOffset.fromSeconds(8 * 3_600));
    const start = try datetime.startOfDay();
    const end = try datetime.endOfDay();

    try testing.expectEqual(@as(u8, 0), (try start.toLocal()).hour);
    try testing.expectEqual(@as(u32, 0), start.instant.nanosecond);
    try testing.expectEqual(@as(u8, 23), (try end.toLocal()).hour);
    try testing.expectEqual(@as(u32, 999_999_999), end.instant.nanosecond);
}
