//! 无状态的公历计算，以及 Unix 秒与日期时间之间的转换。
//! Stateless Gregorian calculations and conversion between Unix seconds and date-time fields.

const std = @import("std");

const days_per_era: i64 = 146_097;
const days_to_unix_epoch: i64 = 719_468;
const seconds_per_minute: i64 = 60;
const seconds_per_hour: i64 = 3_600;
const seconds_per_day: i64 = 86_400;

pub const ValidationError = error{
    InvalidMonth,
    InvalidDay,
    InvalidHour,
    InvalidMinute,
    InvalidSecond,
    InvalidNanosecond,
};

pub const ConversionError = ValidationError || error{YearOutOfRange};

pub const Weekday = enum(u3) {
    sunday,
    monday,
    tuesday,
    wednesday,
    thursday,
    friday,
    saturday,
};

pub const MonthOverflowPolicy = enum {
    reject,
    clamp,
    preserve_end_of_month,
};

/// 无时区的预推格里高利历墙上时间，包含 ISO 8601 的年份 0。
/// Zone-free proleptic Gregorian wall time, including ISO 8601 year zero.
pub const LocalDateTime = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    nanosecond: u32 = 0,

    pub fn validate(date_time: LocalDateTime) ValidationError!void {
        const maximum_day = try daysInMonth(date_time.year, date_time.month);
        if (date_time.day == 0 or date_time.day > maximum_day) {
            return error.InvalidDay;
        }
        if (date_time.hour > 23) return error.InvalidHour;
        if (date_time.minute > 59) return error.InvalidMinute;
        if (date_time.second > 59) return error.InvalidSecond;
        if (date_time.nanosecond >= 1_000_000_000) {
            return error.InvalidNanosecond;
        }
    }

    pub fn weekday(date_time: LocalDateTime) ValidationError!Weekday {
        try date_time.validate();
        return weekdayFromDays(daysFromCivil(
            date_time.year,
            date_time.month,
            date_time.day,
        ));
    }

    pub fn dayOfYear(date_time: LocalDateTime) ValidationError!u16 {
        try date_time.validate();
        var ordinal: u16 = date_time.day;
        var month: u8 = 1;
        while (month < date_time.month) : (month += 1) {
            ordinal += try daysInMonth(date_time.year, month);
        }
        return ordinal;
    }

    pub fn addMonths(
        date_time: LocalDateTime,
        months: i64,
        policy: MonthOverflowPolicy,
    ) (ConversionError || error{Overflow})!LocalDateTime {
        try date_time.validate();
        const current_index = @as(i64, date_time.year) * 12 + date_time.month - 1;
        const target_index = try std.math.add(i64, current_index, months);
        const target_year = @divFloor(target_index, 12);
        const target_month: u8 = @intCast(@mod(target_index, 12) + 1);
        const year = std.math.cast(i32, target_year) orelse return error.YearOutOfRange;
        const source_maximum = try daysInMonth(date_time.year, date_time.month);
        const target_maximum = try daysInMonth(year, target_month);

        var result = date_time;
        result.year = year;
        result.month = target_month;
        result.day = switch (policy) {
            .reject => if (date_time.day > target_maximum)
                return error.InvalidDay
            else
                date_time.day,
            .clamp => @min(date_time.day, target_maximum),
            .preserve_end_of_month => if (date_time.day == source_maximum)
                target_maximum
            else
                @min(date_time.day, target_maximum),
        };
        return result;
    }

    pub fn addYears(
        date_time: LocalDateTime,
        years: i64,
        policy: MonthOverflowPolicy,
    ) (ConversionError || error{Overflow})!LocalDateTime {
        return date_time.addMonths(try std.math.mul(i64, years, 12), policy);
    }

    pub fn addDays(
        date_time: LocalDateTime,
        days: i64,
    ) (ConversionError || error{Overflow})!LocalDateTime {
        try date_time.validate();
        const current_day = daysFromCivil(date_time.year, date_time.month, date_time.day);
        const target = try civilFromDays(try std.math.add(i64, current_day, days));
        var result = date_time;
        result.year = target.year;
        result.month = target.month;
        result.day = target.day;
        return result;
    }
};

pub fn isLeapYear(year: i32) bool {
    return @mod(year, 4) == 0 and
        (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

pub fn daysInMonth(year: i32, month: u8) error{InvalidMonth}!u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => error.InvalidMonth,
    };
}

pub fn localDateTimeFromUnix(unix_seconds: i64) ConversionError!LocalDateTime {
    const days = @divFloor(unix_seconds, seconds_per_day);
    var remaining_seconds = @mod(unix_seconds, seconds_per_day);

    const hour: u8 = @intCast(@divFloor(
        remaining_seconds,
        seconds_per_hour,
    ));
    remaining_seconds = @mod(remaining_seconds, seconds_per_hour);
    const minute: u8 = @intCast(@divFloor(
        remaining_seconds,
        seconds_per_minute,
    ));
    const second: u8 = @intCast(@mod(
        remaining_seconds,
        seconds_per_minute,
    ));

    const civil_date = try civilFromDays(days);
    return .{
        .year = civil_date.year,
        .month = civil_date.month,
        .day = civil_date.day,
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}

pub fn unixSecondsFromLocal(date_time: LocalDateTime) ValidationError!i64 {
    try date_time.validate();
    const days = daysFromCivil(
        date_time.year,
        date_time.month,
        date_time.day,
    );
    return days * seconds_per_day +
        @as(i64, date_time.hour) * seconds_per_hour +
        @as(i64, date_time.minute) * seconds_per_minute +
        date_time.second;
}

const CivilDate = struct {
    year: i32,
    month: u8,
    day: u8,
};

fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const adjusted_year = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(adjusted_year, 400);
    const year_of_era = adjusted_year - era * 400;
    const month_index = @as(i64, month) +
        (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * month_index + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 +
        @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) +
        day_of_year;
    return era * days_per_era + day_of_era - days_to_unix_epoch;
}

fn civilFromDays(days: i64) error{YearOutOfRange}!CivilDate {
    const shifted_days = days + days_to_unix_epoch;
    const era = @divFloor(shifted_days, days_per_era);
    const day_of_era = shifted_days - era * days_per_era;
    const year_of_era = @divFloor(
        day_of_era -
            @divFloor(day_of_era, 1_460) +
            @divFloor(day_of_era, 36_524) -
            @divFloor(day_of_era, 146_096),
        365,
    );
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era -
        (365 * year_of_era +
            @divFloor(year_of_era, 4) -
            @divFloor(year_of_era, 100));
    const month_index = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_index + 2, 5) + 1;
    const month = month_index + (if (month_index < 10) @as(i64, 3) else -9);
    year += @intFromBool(month <= 2);

    return .{
        .year = std.math.cast(i32, year) orelse return error.YearOutOfRange,
        .month = @intCast(month),
        .day = @intCast(day),
    };
}

fn weekdayFromDays(days: i64) Weekday {
    const weekday_index: u3 = @intCast(@mod(days + 4, 7));
    return @enumFromInt(weekday_index);
}

const testing = std.testing;

test "isLeapYear applies Gregorian rules" {
    try testing.expect(isLeapYear(2000));
    try testing.expect(isLeapYear(2024));
    try testing.expect(!isLeapYear(1900));
    try testing.expect(!isLeapYear(2023));
}

test "daysInMonth rejects an invalid month" {
    try testing.expectEqual(@as(u8, 29), try daysInMonth(2024, 2));
    try testing.expectError(error.InvalidMonth, daysInMonth(2024, 13));
}

test "LocalDateTime validation rejects invalid calendar values" {
    try testing.expectError(error.InvalidDay, (LocalDateTime{
        .year = 2023,
        .month = 2,
        .day = 29,
    }).validate());
    try testing.expectError(error.InvalidHour, (LocalDateTime{
        .year = 2024,
        .month = 1,
        .day = 1,
        .hour = 24,
    }).validate());
}

test "Unix conversion handles the epoch and negative seconds" {
    const epoch = try localDateTimeFromUnix(0);
    try testing.expectEqual(LocalDateTime{
        .year = 1970,
        .month = 1,
        .day = 1,
    }, epoch);

    const before_epoch = try localDateTimeFromUnix(-1);
    try testing.expectEqual(LocalDateTime{
        .year = 1969,
        .month = 12,
        .day = 31,
        .hour = 23,
        .minute = 59,
        .second = 59,
    }, before_epoch);
}

test "Unix conversion round trips across calendar boundaries" {
    const samples = [_]i64{
        -2_208_988_800,
        -1,
        0,
        951_782_400,
        1_705_320_000,
        4_102_444_800,
    };

    for (samples) |unix_seconds| {
        const date_time = try localDateTimeFromUnix(unix_seconds);
        try testing.expectEqual(
            unix_seconds,
            try unixSecondsFromLocal(date_time),
        );
    }
}

test "LocalDateTime computes weekdays without stored derived state" {
    const epoch = LocalDateTime{ .year = 1970, .month = 1, .day = 1 };
    try testing.expectEqual(Weekday.thursday, try epoch.weekday());
}

test "LocalDateTime computes one-based day of year" {
    const leap_day = LocalDateTime{ .year = 2024, .month = 2, .day = 29 };
    try testing.expectEqual(@as(u16, 60), try leap_day.dayOfYear());

    const year_end = LocalDateTime{ .year = 2023, .month = 12, .day = 31 };
    try testing.expectEqual(@as(u16, 365), try year_end.dayOfYear());
}

test "Gregorian leap rules include century boundaries" {
    try testing.expect(isLeapYear(2000));
    try testing.expect(!isLeapYear(1900));
    try testing.expect(!isLeapYear(2100));
}

test "month arithmetic requires an explicit overflow policy" {
    const january = LocalDateTime{ .year = 2024, .month = 1, .day = 31 };
    try testing.expectError(error.InvalidDay, january.addMonths(1, .reject));
    try testing.expectEqual(
        @as(u8, 29),
        (try january.addMonths(1, .clamp)).day,
    );

    const april_end = LocalDateTime{ .year = 2024, .month = 4, .day = 30 };
    try testing.expectEqual(
        @as(u8, 31),
        (try april_end.addMonths(1, .preserve_end_of_month)).day,
    );
}

test "leap seconds are rejected on the POSIX calendar path" {
    try testing.expectError(error.InvalidSecond, (LocalDateTime{
        .year = 2016,
        .month = 12,
        .day = 31,
        .hour = 23,
        .minute = 59,
        .second = 60,
    }).validate());
}

test "calendar is explicitly proleptic Gregorian and includes year zero" {
    const dates = [_]LocalDateTime{
        .{ .year = 0, .month = 1, .day = 1 },
        .{ .year = 1582, .month = 10, .day = 5 },
    };
    for (dates) |date| {
        const seconds = try unixSecondsFromLocal(date);
        try testing.expectEqual(date, try localDateTimeFromUnix(seconds));
    }
}

test "calendar day arithmetic preserves wall-clock fields across months" {
    const start = LocalDateTime{
        .year = 2024,
        .month = 2,
        .day = 28,
        .hour = 9,
        .nanosecond = 12,
    };
    const finish = try start.addDays(2);
    try testing.expectEqual(@as(u8, 3), finish.month);
    try testing.expectEqual(@as(u8, 1), finish.day);
    try testing.expectEqual(start.hour, finish.hour);
    try testing.expectEqual(start.nanosecond, finish.nanosecond);
}
