//! 严格解析无时区墙上时间与带数字偏移的 RFC 3339 时间。
//! Strictly parses zone-free wall time and RFC 3339 timestamps with numeric offsets.

const std = @import("std");
const calendar = @import("calendar.zig");
const OffsetDateTime = @import("offset_datetime.zig").OffsetDateTime;
const timezone = @import("timezone.zig");

pub const ParseError = error{
    EmptyLayout,
    DanglingEscape,
    DuplicateField,
    MissingDateField,
    UnexpectedEnd,
    TrailingInput,
    InvalidFraction,
    InvalidValue,
    LiteralMismatch,
    Overflow,
} || calendar.ValidationError || timezone.OffsetParseError;

const SeenFields = struct {
    year: bool = false,
    month: bool = false,
    day: bool = false,
    hour: bool = false,
    minute: bool = false,
    second: bool = false,
    nanosecond: bool = false,

    fn mark(seen: *SeenFields, token: u8) error{DuplicateField}!void {
        const field = switch (token) {
            'Y' => &seen.year,
            'm' => &seen.month,
            'd' => &seen.day,
            'H' => &seen.hour,
            'M' => &seen.minute,
            'S' => &seen.second,
            'f' => &seen.nanosecond,
            else => unreachable,
        };
        if (field.*) return error.DuplicateField;
        field.* = true;
    }

    fn hasDate(seen: SeenFields) bool {
        return seen.year and seen.month and seen.day;
    }
};

const Input = struct {
    bytes: []const u8,
    index: usize = 0,

    fn takeUnsigned(
        input: *Input,
        comptime T: type,
        length: usize,
    ) error{ UnexpectedEnd, InvalidValue }!T {
        const end = input.index + length;
        if (end > input.bytes.len) return error.UnexpectedEnd;
        const value = std.fmt.parseUnsigned(T, input.bytes[input.index..end], 10) catch
            return error.InvalidValue;
        input.index = end;
        return value;
    }

    fn takeLiteral(input: *Input, expected: u8) error{
        UnexpectedEnd,
        LiteralMismatch,
    }!void {
        if (input.index == input.bytes.len) return error.UnexpectedEnd;
        if (input.bytes[input.index] != expected) return error.LiteralMismatch;
        input.index += 1;
    }
};

/// `Y`、`m`、`d` 必须各出现一次；未出现的时间字段明确为零。
/// `Y`, `m`, and `d` must each occur once; omitted time fields are explicitly zero.
pub fn localDateTime(
    layout: []const u8,
    text: []const u8,
) ParseError!calendar.LocalDateTime {
    if (layout.len == 0) return error.EmptyLayout;

    var result = calendar.LocalDateTime{ .year = 0, .month = 1, .day = 1 };
    var seen: SeenFields = .{};
    var input = Input{ .bytes = text };
    var layout_index: usize = 0;

    while (layout_index < layout.len) : (layout_index += 1) {
        var token = layout[layout_index];
        if (token == '\\') {
            layout_index += 1;
            if (layout_index == layout.len) return error.DanglingEscape;
            token = layout[layout_index];
            try input.takeLiteral(token);
            continue;
        }

        switch (token) {
            'Y' => {
                try seen.mark(token);
                result.year = try input.takeUnsigned(i32, 4);
            },
            'm' => {
                try seen.mark(token);
                result.month = try input.takeUnsigned(u8, 2);
            },
            'd' => {
                try seen.mark(token);
                result.day = try input.takeUnsigned(u8, 2);
            },
            'H' => {
                try seen.mark(token);
                result.hour = try input.takeUnsigned(u8, 2);
            },
            'M' => {
                try seen.mark(token);
                result.minute = try input.takeUnsigned(u8, 2);
            },
            'S' => {
                try seen.mark(token);
                result.second = try input.takeUnsigned(u8, 2);
            },
            'f' => {
                try seen.mark(token);
                result.nanosecond = try input.takeUnsigned(u32, 9);
            },
            else => try input.takeLiteral(token),
        }
    }

    if (!seen.hasDate()) return error.MissingDateField;
    if (input.index != text.len) return error.TrailingInput;
    try result.validate();
    return result;
}

/// 解析 `YYYY-MM-DDTHH:MM:SS[.1-9位小数](Z|+HH:MM|-HH:MM)`。
/// Parses `YYYY-MM-DDTHH:MM:SS[.1-9 fractional digits](Z|+HH:MM|-HH:MM)`.
pub fn rfc3339(text: []const u8) ParseError!OffsetDateTime {
    const date_time_length = 19;
    if (text.len <= date_time_length) return error.UnexpectedEnd;

    var suffix_index: usize = date_time_length;
    var nanosecond: u32 = 0;
    if (text[suffix_index] == '.') {
        suffix_index += 1;
        const fraction_start = suffix_index;
        while (suffix_index < text.len and isDigit(text[suffix_index])) {
            suffix_index += 1;
        }
        const fraction_length = suffix_index - fraction_start;
        if (fraction_length == 0 or fraction_length > 9) return error.InvalidFraction;
        nanosecond = std.fmt.parseUnsigned(u32, text[fraction_start..suffix_index], 10) catch
            return error.InvalidFraction;
        var padding = 9 - fraction_length;
        while (padding > 0) : (padding -= 1) nanosecond *= 10;
    }

    if (suffix_index == text.len) return error.UnexpectedEnd;
    const offset = try timezone.UtcOffset.parseRfc3339(text[suffix_index..]);
    var local = try localDateTime("Y-m-dTH:M:S", text[0..date_time_length]);
    local.nanosecond = nanosecond;
    return OffsetDateTime.fromLocal(local, offset);
}

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

const testing = std.testing;

test "localDateTime parses wall time without inventing a zone" {
    const local = try localDateTime("Y/m/d H:M", "2024/01/15 08:00");
    try testing.expectEqual(@as(u8, 8), local.hour);
    try testing.expectEqual(@as(u32, 0), local.nanosecond);
}

test "localDateTime rejects invalid dates instead of normalizing" {
    try testing.expectError(error.InvalidDay, localDateTime("Y-m-d", "2026-02-31"));
    try testing.expectError(error.InvalidSecond, localDateTime(
        "Y-m-dTH:M:S",
        "2016-12-31T23:59:60",
    ));
}

test "rfc3339 requires an explicit unambiguous offset" {
    const utc = try rfc3339("2024-01-15T00:00:00Z");
    const offset = try rfc3339("2024-01-15T08:00:00.123+08:00");
    try testing.expectEqual(utc.instant.unix_seconds, offset.instant.unix_seconds);
    try testing.expectEqual(@as(u32, 123_000_000), offset.instant.nanosecond);
    try testing.expectError(error.UnexpectedEnd, rfc3339("2024-01-15T00:00:00"));
    try testing.expectError(error.InvalidFormat, rfc3339("2024-01-15T00:00:00 CST"));
}

test "rfc3339 rejects excessive fractional precision" {
    try testing.expectError(
        error.InvalidFraction,
        rfc3339("2024-01-15T00:00:00.1234567890Z"),
    );
}

test "localDateTime rejects incomplete, duplicate, and trailing fields" {
    try testing.expectError(error.UnexpectedEnd, localDateTime("Y-m-d", "2024-01"));
    try testing.expectError(
        error.DuplicateField,
        localDateTime("Y-Y-m-d", "2024-2024-01-15"),
    );
    try testing.expectError(
        error.TrailingInput,
        localDateTime("Y-m-d", "2024-01-15 trailing"),
    );
}

test "localDateTime supports nanoseconds and escaped layout tokens" {
    const local = try localDateTime(
        "Y-\\Y-m-d H:M:S.f",
        "2024-Y-01-15 08:30:45.123456789",
    );
    try testing.expectEqual(@as(u32, 123_456_789), local.nanosecond);
    try testing.expectError(
        error.DanglingEscape,
        localDateTime("Y-m-d\\", "2024-01-15"),
    );
}
