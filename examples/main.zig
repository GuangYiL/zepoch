const std = @import("std");
const zepoch = @import("zepoch");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const now = try zepoch.Instant.now(init.io);
    try writeOffsetTime(stdout, "UTC+08:00", .{
        .instant = now,
        .offset = try zepoch.UtcOffset.fromSeconds(8 * 3_600),
    });
    try writeOffsetTime(stdout, "UTC+09:00", .{
        .instant = now,
        .offset = try zepoch.UtcOffset.fromSeconds(9 * 3_600),
    });

    const january = try zepoch.parse.localDateTime("Y-m-d", "2024-01-31");
    const february = try january.addMonths(1, .clamp);
    try zepoch.format.writeLocal(february, "Y年m月d日", stdout);
    try stdout.writeByte('\n');

    const parsed = try zepoch.parse.rfc3339("2024-01-31T23:59:59.5+08:00");
    const later = zepoch.OffsetDateTime{
        .instant = try parsed.instant.add(zepoch.Duration.fromMilliseconds(1_500)),
        .offset = parsed.offset,
    };
    try writeOffsetTime(stdout, "增加 1500 毫秒后", later);
    try stdout.flush();
}

fn writeOffsetTime(
    writer: *std.Io.Writer,
    label: []const u8,
    datetime: zepoch.OffsetDateTime,
) !void {
    try writer.print("{s}: ", .{label});
    try zepoch.format.writeRfc3339(datetime, writer);
    try writer.writeByte('\n');
}
