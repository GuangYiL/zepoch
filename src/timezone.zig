//! 固定 UTC 偏移与调用方提供 TZif 数据的 IANA 时区转换。
//! Fixed UTC offsets and IANA time-zone conversion from caller-provided TZif data.

const std = @import("std");
const calendar = @import("calendar.zig");
const Instant = @import("instant.zig").Instant;

const maximum_offset_seconds: i32 = 23 * 3_600 + 59 * 60 + 59;

pub const OffsetError = error{OutOfRange};

pub const OffsetParseError = OffsetError || error{
    InvalidFormat,
    InvalidValue,
    UnknownLocalOffset,
};

pub const UtcOffset = struct {
    seconds: i32,

    pub const utc: UtcOffset = .{ .seconds = 0 };

    pub fn fromSeconds(seconds: i32) OffsetError!UtcOffset {
        if (seconds < -maximum_offset_seconds or seconds > maximum_offset_seconds) {
            return error.OutOfRange;
        }
        return .{ .seconds = seconds };
    }

    pub fn parseRfc3339(text: []const u8) OffsetParseError!UtcOffset {
        if (std.mem.eql(u8, text, "Z")) return .utc;
        if (std.mem.eql(u8, text, "-00:00")) return error.UnknownLocalOffset;
        if (text.len != 6 or text[3] != ':') return error.InvalidFormat;
        if (text[0] != '+' and text[0] != '-') return error.InvalidFormat;

        const hours = std.fmt.parseUnsigned(u8, text[1..3], 10) catch
            return error.InvalidValue;
        const minutes = std.fmt.parseUnsigned(u8, text[4..6], 10) catch
            return error.InvalidValue;
        if (hours > 23 or minutes > 59) return error.OutOfRange;

        const magnitude = @as(i32, hours) * 3_600 + @as(i32, minutes) * 60;
        return fromSeconds(if (text[0] == '-') -magnitude else magnitude);
    }
};

pub const ZoneState = struct {
    offset_seconds: i32,
    is_dst: bool,
    designation: []const u8,
};

pub const AmbiguousInstants = struct {
    earlier: Instant,
    later: Instant,
};

pub const LocalResolution = union(enum) {
    outside_coverage,
    nonexistent,
    unique: Instant,
    ambiguous: AmbiguousInstants,
};

pub const TzifZone = struct {
    /// 标识符借用调用方内存；TZif 文件本身不包含 IANA 标识符。
    /// The identifier borrows caller memory; a TZif file does not contain its IANA identifier.
    identifier: []const u8,
    data: std.Tz,

    pub fn parse(
        allocator: std.mem.Allocator,
        identifier: []const u8,
        bytes: []const u8,
    ) !TzifZone {
        if (std.mem.indexOfScalar(u8, identifier, '/') == null or
            std.mem.indexOfScalar(u8, identifier, 0) != null)
        {
            return error.InvalidIdentifier;
        }
        var stream = std.io.fixedBufferStream(bytes);
        var data = try std.Tz.parse(allocator, stream.reader());
        errdefer data.deinit();
        try validateTransitions(data.transitions);
        return .{
            .identifier = identifier,
            .data = data,
        };
    }

    pub fn deinit(zone: *TzifZone) void {
        zone.data.deinit();
        zone.* = undefined;
    }

    /// 只在两个相邻 TZif 转换点之间返回结果，避免忽略 POSIX footer 后静默给错。
    /// Returns results only between adjacent TZif transitions to avoid ignoring the POSIX footer.
    pub fn stateAt(zone: TzifZone, instant: Instant) error{OutsideCoverage}!ZoneState {
        const transitions = zone.data.transitions;
        if (transitions.len < 2 or
            instant.unix_seconds < transitions[0].ts or
            instant.unix_seconds >= transitions[transitions.len - 1].ts)
        {
            return error.OutsideCoverage;
        }

        const index = transitionIndex(transitions, instant.unix_seconds);
        const timetype = transitions[index].timetype;
        return .{
            .offset_seconds = timetype.offset,
            .is_dst = timetype.isDst(),
            .designation = timetype.name(),
        };
    }

    pub fn resolveLocal(
        zone: TzifZone,
        local: calendar.LocalDateTime,
    ) (calendar.ValidationError || error{ Overflow, MalformedTransitions })!LocalResolution {
        const local_seconds = try calendar.unixSecondsFromLocal(local);
        const transitions = zone.data.transitions;
        if (transitions.len < 2) return .outside_coverage;

        var candidates: [2]Instant = undefined;
        var candidate_count: usize = 0;
        for (transitions[0 .. transitions.len - 1], 0..) |transition, index| {
            const candidate_seconds = std.math.sub(
                i64,
                local_seconds,
                transition.timetype.offset,
            ) catch continue;
            if (candidate_seconds < transition.ts or
                candidate_seconds >= transitions[index + 1].ts)
            {
                continue;
            }
            if (candidate_count == candidates.len) return error.MalformedTransitions;
            candidates[candidate_count] = try Instant.fromUnixSeconds(
                candidate_seconds,
                local.nanosecond,
            );
            candidate_count += 1;
        }

        if (candidate_count == 1) return .{ .unique = candidates[0] };
        if (candidate_count == 2) {
            const first_is_earlier = candidates[0].order(candidates[1]) == .lt;
            return .{ .ambiguous = .{
                .earlier = if (first_is_earlier) candidates[0] else candidates[1],
                .later = if (first_is_earlier) candidates[1] else candidates[0],
            } };
        }

        var index: usize = 1;
        while (index + 1 < transitions.len) : (index += 1) {
            const before = transitions[index - 1].timetype.offset;
            const after = transitions[index].timetype.offset;
            if (after <= before) continue;
            const gap_start = try std.math.add(i64, transitions[index].ts, before);
            const gap_end = try std.math.add(i64, transitions[index].ts, after);
            if (local_seconds >= gap_start and local_seconds < gap_end) {
                return .nonexistent;
            }
        }
        return .outside_coverage;
    }

    pub fn toLocal(
        zone: TzifZone,
        instant: Instant,
    ) (error{Overflow} || calendar.ConversionError || error{OutsideCoverage})!calendar.LocalDateTime {
        const state = try zone.stateAt(instant);
        const local_seconds = try std.math.add(
            i64,
            instant.unix_seconds,
            state.offset_seconds,
        );
        var local = try calendar.localDateTimeFromUnix(local_seconds);
        local.nanosecond = instant.nanosecond;
        return local;
    }

    pub fn leapSecondRecords(zone: TzifZone) []const std.tz.Leapsecond {
        return zone.data.leapseconds;
    }
};

fn transitionIndex(transitions: []const std.tz.Transition, unix_seconds: i64) usize {
    var low: usize = 0;
    var high = transitions.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (transitions[middle].ts <= unix_seconds) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low - 1;
}

fn validateTransitions(transitions: []const std.tz.Transition) error{MalformedTransitions}!void {
    if (transitions.len < 2) return;
    for (transitions[0 .. transitions.len - 1], transitions[1..]) |previous, next| {
        if (previous.ts >= next.ts) return error.MalformedTransitions;
    }
}

fn testZone(types: *[2]std.tz.Timetype, transitions: *[4]std.tz.Transition) TzifZone {
    types.* = .{
        .{ .offset = -5 * 3_600, .flags = 0, .name_data = .{ 'E', 'S', 'T', 0, 0, 0 } },
        .{ .offset = -4 * 3_600, .flags = 1, .name_data = .{ 'E', 'D', 'T', 0, 0, 0 } },
    };
    transitions.* = .{
        .{ .ts = 1_700_000_000, .timetype = &types[0] },
        .{ .ts = 1_710_054_000, .timetype = &types[1] },
        .{ .ts = 1_730_613_600, .timetype = &types[0] },
        .{ .ts = 1_741_503_600, .timetype = &types[1] },
    };
    return .{
        .identifier = "America/New_York",
        .data = .{
            .allocator = std.testing.allocator,
            .transitions = transitions,
            .timetypes = types,
            .leapseconds = &.{},
            .footer = null,
        },
    };
}

const testing = std.testing;

test "UtcOffset parses RFC 3339 offsets without guessing abbreviations" {
    try testing.expectEqual(UtcOffset.utc, try UtcOffset.parseRfc3339("Z"));
    try testing.expectEqual(@as(i32, 19_800), (try UtcOffset.parseRfc3339("+05:30")).seconds);
    try testing.expectError(error.InvalidFormat, UtcOffset.parseRfc3339("CST"));
    try testing.expectError(error.UnknownLocalOffset, UtcOffset.parseRfc3339("-00:00"));
}

test "UtcOffset preserves historical second precision and validates its range" {
    try testing.expectEqual(@as(i32, 30), (try UtcOffset.fromSeconds(30)).seconds);
    try testing.expectError(error.OutOfRange, UtcOffset.fromSeconds(24 * 3_600));
    try testing.expectError(error.InvalidValue, UtcOffset.parseRfc3339("+0X:00"));
    try testing.expectError(error.OutOfRange, UtcOffset.parseRfc3339("+24:00"));
}

test "TZif parser rejects ambiguous abbreviation identifiers before allocation" {
    try testing.expectError(
        error.InvalidIdentifier,
        TzifZone.parse(testing.allocator, "CST", &.{}),
    );
}

test "TZif parser accepts a valid version 1 UTC file" {
    var bytes = [_]u8{0} ** 54;
    @memcpy(bytes[0..4], "TZif");
    bytes[39] = 1;
    bytes[43] = 4;
    @memcpy(bytes[50..54], "UTC\x00");

    var zone = try TzifZone.parse(testing.allocator, "Etc/UTC", &bytes);
    defer zone.deinit();
    try testing.expectEqual(@as(usize, 1), zone.data.timetypes.len);
    try testing.expectEqualStrings("UTC", zone.data.timetypes[0].name());
}

test "TZif zone reports spring gaps and autumn folds explicitly" {
    var types: [2]std.tz.Timetype = undefined;
    var transitions: [4]std.tz.Transition = undefined;
    const zone = testZone(&types, &transitions);

    const gap = try zone.resolveLocal(.{
        .year = 2024,
        .month = 3,
        .day = 10,
        .hour = 2,
        .minute = 30,
    });
    try testing.expect(gap == .nonexistent);

    const fold = try zone.resolveLocal(.{
        .year = 2024,
        .month = 11,
        .day = 3,
        .hour = 1,
        .minute = 30,
    });
    try testing.expect(fold == .ambiguous);
    try testing.expectEqual(@as(i64, 3_600), fold.ambiguous.later.unix_seconds -
        fold.ambiguous.earlier.unix_seconds);
}

test "TZif zone fails outside its proven transition coverage" {
    var types: [2]std.tz.Timetype = undefined;
    var transitions: [4]std.tz.Transition = undefined;
    const zone = testZone(&types, &transitions);
    const before = try Instant.fromUnixSeconds(transitions[0].ts - 1, 0);
    const after = try Instant.fromUnixSeconds(transitions[3].ts, 0);

    try testing.expectError(error.OutsideCoverage, zone.stateAt(before));
    try testing.expectError(error.OutsideCoverage, zone.stateAt(after));
}

test "TZif resolution represents Samoa 2011 skipped day as nonexistent" {
    var types = [_]std.tz.Timetype{
        .{ .offset = -11 * 3_600, .flags = 0, .name_data = .{ '-', '1', '1', 0, 0, 0 } },
        .{ .offset = 13 * 3_600, .flags = 0, .name_data = .{ '+', '1', '3', 0, 0, 0 } },
    };
    var transitions = [_]std.tz.Transition{
        .{ .ts = 1_300_000_000, .timetype = &types[0] },
        .{ .ts = 1_325_242_800, .timetype = &types[1] },
        .{ .ts = 1_400_000_000, .timetype = &types[1] },
    };
    const zone = TzifZone{
        .identifier = "Pacific/Apia",
        .data = .{
            .allocator = testing.allocator,
            .transitions = &transitions,
            .timetypes = &types,
            .leapseconds = &.{},
            .footer = null,
        },
    };

    const skipped = try zone.resolveLocal(.{
        .year = 2011,
        .month = 12,
        .day = 30,
        .hour = 12,
    });
    try testing.expect(skipped == .nonexistent);
}

test "TZif transition validation rejects unordered data" {
    var timetype = std.tz.Timetype{
        .offset = 0,
        .flags = 0,
        .name_data = .{ 'U', 'T', 'C', 0, 0, 0 },
    };
    const transitions = [_]std.tz.Transition{
        .{ .ts = 2, .timetype = &timetype },
        .{ .ts = 1, .timetype = &timetype },
    };
    try testing.expectError(error.MalformedTransitions, validateTransitions(&transitions));
}
