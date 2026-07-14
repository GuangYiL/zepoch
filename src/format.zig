//! 将调用方选择的时间类型写入显式 `std.Io.Writer`，不分配内存。
//! Writes caller-selected time types to an explicit `std.Io.Writer` without allocation.

const std = @import("std");
const calendar = @import("calendar.zig");
const OffsetDateTime = @import("offset_datetime.zig").OffsetDateTime;

pub const WriteError = calendar.ValidationError ||
    calendar.ConversionError ||
    error{ Overflow, DanglingEscape, OffsetPrecisionLoss } ||
    std.Io.Writer.Error;

/// 支持 `Y`、`m`、`d`、`H`、`M`、`S`、`f`，反斜杠转义下一字节。
/// Supports `Y`, `m`, `d`, `H`, `M`, `S`, and `f`; a backslash escapes the next byte.
pub fn writeLocal(
    local: calendar.LocalDateTime,
    layout: []const u8,
    writer: *std.Io.Writer,
) WriteError!void {
    try local.validate();
    var layout_index: usize = 0;
    while (layout_index < layout.len) : (layout_index += 1) {
        var token = layout[layout_index];
        if (token == '\\') {
            layout_index += 1;
            if (layout_index == layout.len) return error.DanglingEscape;
            token = layout[layout_index];
            try writer.writeByte(token);
            continue;
        }

        switch (token) {
            'Y' => try writeYear(local.year, writer),
            'm' => try writer.print("{d:0>2}", .{local.month}),
            'd' => try writer.print("{d:0>2}", .{local.day}),
            'H' => try writer.print("{d:0>2}", .{local.hour}),
            'M' => try writer.print("{d:0>2}", .{local.minute}),
            'S' => try writer.print("{d:0>2}", .{local.second}),
            'f' => try writer.print("{d:0>9}", .{local.nanosecond}),
            else => try writer.writeByte(token),
        }
    }
}

pub fn writeRfc3339(
    datetime: OffsetDateTime,
    writer: *std.Io.Writer,
) WriteError!void {
    const local = try datetime.toLocal();
    if (local.year < 0 or local.year > 9_999) return error.YearOutOfRange;
    if (@mod(datetime.offset.seconds, 60) != 0) return error.OffsetPrecisionLoss;

    try writeLocal(local, "Y-m-dTH:M:S", writer);
    if (local.nanosecond != 0) try writeFraction(local.nanosecond, writer);

    const offset_seconds = datetime.offset.seconds;
    if (offset_seconds == 0) {
        try writer.writeByte('Z');
        return;
    }
    const absolute_seconds: u32 = @abs(offset_seconds);
    const sign: u8 = if (offset_seconds < 0) '-' else '+';
    try writer.print("{c}{d:0>2}:{d:0>2}", .{
        sign,
        absolute_seconds / 3_600,
        absolute_seconds % 3_600 / 60,
    });
}

fn writeFraction(nanosecond: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var digits: [9]u8 = undefined;
    var value = nanosecond;
    var index = digits.len;
    while (index > 0) {
        index -= 1;
        digits[index] = @intCast('0' + value % 10);
        value /= 10;
    }
    var end = digits.len;
    while (digits[end - 1] == '0') end -= 1;
    try writer.writeByte('.');
    try writer.writeAll(digits[0..end]);
}

fn writeYear(
    year: i32,
    writer: *std.Io.Writer,
) (std.Io.Writer.Error || error{YearOutOfRange})!void {
    if (year < 0 or year > 9_999) return error.YearOutOfRange;
    try writer.print("{d:0>4}", .{@as(u32, @intCast(year))});
}

const testing = std.testing;

test "writeLocal formats wall time without implying a zone" {
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeLocal(.{
        .year = 2024,
        .month = 5,
        .day = 6,
        .hour = 7,
        .minute = 8,
        .second = 9,
    }, "Y/m/d H:M:S", &writer);
    try testing.expectEqualStrings("2024/05/06 07:08:09", writer.buffered());
}

test "writeRfc3339 preserves offset and nanosecond precision" {
    const datetime = try OffsetDateTime.fromLocal(.{
        .year = 1970,
        .month = 1,
        .day = 1,
        .hour = 5,
        .minute = 30,
        .nanosecond = 123_000_000,
    }, .{ .seconds = 19_800 });
    var buffer: [48]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeRfc3339(datetime, &writer);
    try testing.expectEqualStrings("1970-01-01T05:30:00.123+05:30", writer.buffered());
}

test "writeRfc3339 rejects offsets that lose historical seconds" {
    const datetime = OffsetDateTime{
        .instant = try @import("instant.zig").Instant.fromUnixSeconds(0, 0),
        .offset = .{ .seconds = 30 },
    };
    var buffer: [48]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try testing.expectError(error.OffsetPrecisionLoss, writeRfc3339(datetime, &writer));
}

test "writeLocal supports nanoseconds and escaped layout tokens" {
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeLocal(.{
        .year = 1970,
        .month = 1,
        .day = 1,
        .nanosecond = 123_456_789,
    }, "Y-\\Y-f", &writer);
    try testing.expectEqualStrings("1970-Y-123456789", writer.buffered());

    var invalid_writer = std.Io.Writer.fixed(&buffer);
    try testing.expectError(
        error.DanglingEscape,
        writeLocal(.{ .year = 1970, .month = 1, .day = 1 }, "Y\\", &invalid_writer),
    );
}

test "writeLocal rejects years outside its four-digit layout contract" {
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try testing.expectError(
        error.YearOutOfRange,
        writeLocal(.{ .year = -1, .month = 1, .day = 1 }, "Y-m-d", &writer),
    );
}
