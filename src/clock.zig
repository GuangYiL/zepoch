//! 为 Zig 0.15 提供显式、可注入且无隐藏回退的时钟能力。
//! Explicit, injectable clock capabilities for Zig 0.15 without hidden fallbacks.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{ClockUnavailable};

/// 区分可调整的墙上时钟、仅清醒时间和包含休眠时间的单调时钟。
/// Distinguishes adjustable wall time, awake-only time, and suspend-inclusive monotonic time.
pub const ClockDomain = enum {
    realtime,
    awake,
    boot,
};

/// 调用方显式传入的纳秒时钟能力；上下文由调用方持有。
/// An explicitly supplied nanosecond clock capability whose context remains caller-owned.
pub const Clock = struct {
    domain: ClockDomain,
    context: ?*anyopaque = null,
    read_nanoseconds: *const fn (?*anyopaque) Error!i128,

    pub fn read(clock: Clock) Error!i128 {
        return clock.read_nanoseconds(clock.context);
    }
};

/// 平台的 POSIX 实时时钟；不支持的平台返回 `error.ClockUnavailable`。
/// The platform POSIX realtime clock; unsupported platforms return `error.ClockUnavailable`.
pub const system_realtime_clock = Clock{
    .domain = .realtime,
    .read_nanoseconds = readSystemRealtime,
};

/// 平台的仅清醒单调时钟；不包含系统休眠时间。
/// The platform awake-only monotonic clock; system suspend time is excluded.
pub const system_awake_clock = Clock{
    .domain = .awake,
    .read_nanoseconds = readSystemAwake,
};

/// 平台的启动后单调时钟；支持时包含系统休眠时间。
/// The platform boot-relative monotonic clock; system suspend time is included when supported.
pub const system_boot_clock = Clock{
    .domain = .boot,
    .read_nanoseconds = readSystemBoot,
};

fn readSystemRealtime(_: ?*anyopaque) Error!i128 {
    return switch (builtin.os.tag) {
        .windows => blk: {
            const epoch_adjustment = std.time.epoch.windows * (std.time.ns_per_s / 100);
            const ticks = std.os.windows.ntdll.RtlGetSystemTimePrecise() + epoch_adjustment;
            break :blk @as(i128, ticks) * 100;
        },
        .wasi => readWasi(.REALTIME),
        .uefi => error.ClockUnavailable,
        else => readPosix(.REALTIME),
    };
}

fn readSystemAwake(_: ?*anyopaque) Error!i128 {
    return switch (builtin.os.tag) {
        .windows, .uefi => error.ClockUnavailable,
        .wasi => readWasi(.MONOTONIC),
        else => readPosix(.MONOTONIC),
    };
}

fn readSystemBoot(_: ?*anyopaque) Error!i128 {
    return switch (builtin.os.tag) {
        .windows => readWindowsPerformanceCounter(),
        .macos, .ios, .tvos, .watchos, .visionos => readPosix(.UPTIME_RAW),
        .linux => readPosix(.BOOTTIME),
        .freebsd, .dragonfly => readPosix(.MONOTONIC_FAST),
        else => error.ClockUnavailable,
    };
}

fn readPosix(clock_id: std.posix.clockid_t) Error!i128 {
    const timestamp = std.posix.clock_gettime(clock_id) catch return error.ClockUnavailable;
    return @as(i128, timestamp.sec) * std.time.ns_per_s + timestamp.nsec;
}

fn readWasi(clock_id: std.os.wasi.clockid_t) Error!i128 {
    var nanoseconds: std.os.wasi.timestamp_t = undefined;
    if (std.os.wasi.clock_time_get(clock_id, 1, &nanoseconds) != .SUCCESS) {
        return error.ClockUnavailable;
    }
    return nanoseconds;
}

fn readWindowsPerformanceCounter() i128 {
    const counter = std.os.windows.QueryPerformanceCounter();
    const frequency = std.os.windows.QueryPerformanceFrequency();
    return @divFloor(
        @as(i128, counter) * std.time.ns_per_s,
        @as(i128, frequency),
    );
}

fn fixedNanoseconds(_: ?*anyopaque) Error!i128 {
    return 123;
}

test "Clock delegates reads without hidden global state" {
    const clock = Clock{
        .domain = .realtime,
        .read_nanoseconds = fixedNanoseconds,
    };
    try std.testing.expectEqual(@as(i128, 123), try clock.read());
}
