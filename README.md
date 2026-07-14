# zepoch

<p align="center">
  <img src="assets/logo.png" alt="zepoch logo" width="480">
</p>

[Chinese](README-zh.md)

`zepoch` is an explicit time library for Zig 0.15.2. It separates absolute instants,
wall time, fixed-offset views, and monotonic clocks into distinct types. External
clock capabilities enter through the library's injected `Clock` interface, while
TZif parsing uses `std.Tz`. The library never guesses a time zone, reads process
environment state, or hides allocation.

## Version support

The actively maintained window covers the current stable Zig release, the previous
release series, and the next development series:

| Branch | Zig version | Status |
| --- | --- | --- |
| `zig-0.15` | 0.15.2 | Previous release, maintained |
| `main` | 0.16.0 | Current stable release, maintained |
| `zig-0.17` | 0.17 development snapshots | Next release, maintained preview |

When a new stable Zig release moves this three-series window forward, branches that
fall outside it remain available for reproducible builds but receive no further
compatibility updates, fixes, or maintenance.

## Time model

| Type | Meaning | Supported operations |
| --- | --- | --- |
| `Instant` | POSIX/Unix instant that ignores leap seconds | Timestamp conversion, exact duration arithmetic, ordering |
| `LocalDateTime` | Zone-free wall time | Gregorian validation, weekday, ordinal day, calendar arithmetic |
| `OffsetDateTime` | `Instant` with an explicit fixed UTC offset | RFC 3339 and fixed-offset calendar views |
| `MonotonicInstant` | `awake` or `boot` monotonic clock reading | Timeout and elapsed-time measurement |
| `TzifZone` | IANA transition rules from caller-provided TZif data | Instant conversion and DST gap/fold resolution |

There are no implicit conversions between these types. `Instant` stores no display
offset, `LocalDateTime` assumes no system time zone, and `MonotonicInstant` cannot be
formatted as calendar time. Operations return new values instead of mutating inputs.

## Design rules

- `Instant.now(clock)` and `MonotonicInstant.now(clock)` receive a `Clock` capability
  explicitly. Production callers may pass a system clock; tests may inject a fixed one.
- A system clock returns `error.ClockUnavailable` when the platform cannot honor its
  exact `realtime`, `awake`, or `boot` domain; it never substitutes another clock.
- `TzifZone.parse(allocator, identifier, bytes)` receives the allocator, IANA
  identifier, and TZif bytes explicitly. The caller decides how to obtain them.
- Formatting writes to a caller-provided `*std.Io.Writer` without allocating a string.
- Invalid dates, offsets, precision loss, and arithmetic overflow return errors.
- Month arithmetic requires `.reject`, `.clamp`, or `.preserve_end_of_month`.
- `LocalDateTime.addDays` moves a calendar date while preserving wall-clock fields;
  it does not mean `Duration.fromHours(24)` across DST.
- TZif designations are display data only. Lookups require regional IANA identifiers
  such as `Asia/Shanghai`, `America/New_York`, or `Etc/UTC`.

## POSIX time and leap seconds

`Instant.now(system_realtime_clock)` reads the platform's POSIX-style realtime clock
through an explicit capability and normalizes it into `i64 unix_seconds` plus a
`u32 nanosecond` in `[0, 1_000_000_000)`. Floor division and a non-negative remainder
are used for negative values, so `-1 ns` becomes `-1 s + 999_999_999 ns`.

`Instant` follows POSIX time: it uses the Unix epoch and does not represent inserted
leap seconds. `2016-12-31T23:59:60Z` returns `error.InvalidSecond` instead of being
normalized. `TzifZone.leapSecondRecords()` exposes TZif leap records but does not apply
them to POSIX time. TAI, GPS, UT1, and astronomical applications need a separate time
scale and an authoritative leap-second table.

## Calendar and TZif boundaries

`LocalDateTime` uses the proleptic Gregorian calendar with ISO 8601 year numbering,
including year zero. It does not model the 1582 Julian-to-Gregorian cutover.

`TzifZone` delegates RFC 8536 TZif parsing to the Zig standard library and does not
maintain a tzdb. To avoid silently ignoring future rules in the TZif POSIX footer,
results are available only between adjacent transitions:

- `.unique`: one absolute instant;
- `.ambiguous`: two instants in an autumn fold;
- `.nonexistent`: a local-time gap caused by DST or a date-line change;
- `.outside_coverage`: the transition table cannot prove the result.

## Precision and formatting

`Instant` uses `i64` seconds plus `u32` nanoseconds. `Duration` uses signed `i128`
nanoseconds, and timestamps never use floating point. There is no `fromDays`;
write `Duration.fromHours(24)` when an exact 24-hour duration is intended.

`parse.rfc3339` accepts a four-digit year, `T`, seconds, an optional 1-9 digit
fraction, and `Z` or `±HH:MM`. Invalid dates are never normalized. `-00:00` returns
`error.UnknownLocalOffset`. Formatting a historical offset with second precision
returns `error.OffsetPrecisionLoss` because RFC 3339 cannot represent it.

The library does not provide translated month or weekday names, 12-hour clocks, or
locale-specific week rules. Those policies belong in a caller-selected locale layer.

## Installation

```bash
zig fetch --save https://github.com/GuangYiL/zepoch/archive/refs/heads/zig-0.15.tar.gz
```

```zig
const dependency = build_system.dependency("zepoch", .{
    .target = target,
    .optimize = optimize,
});
executable.root_module.addImport("zepoch", dependency.module("zepoch"));
```

## Usage

```zig
const std = @import("std");
const zepoch = @import("zepoch");

pub fn main() !void {
    const now = try zepoch.Instant.now(zepoch.system_realtime_clock);
    const utc_plus_eight = zepoch.OffsetDateTime{
        .instant = now,
        .offset = try zepoch.UtcOffset.fromSeconds(8 * 3_600),
    };

    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try zepoch.format.writeRfc3339(utc_plus_eight, &writer);
}
```

The caller obtains and caches TZif data for named time zones:

```zig
var zone = try zepoch.TzifZone.parse(
    allocator,
    "America/New_York",
    tzif_bytes,
);
defer zone.deinit();

switch (try zone.resolveLocal(wall_time)) {
    .unique => |instant| use(instant),
    .ambiguous => |pair| chooseExplicitly(pair.earlier, pair.later),
    .nonexistent => return error.NonexistentLocalTime,
    .outside_coverage => return error.TimeZoneDataOutOfRange,
}
```

## Development and commits

```bash
zig version # must print 0.15.2
zig fmt --check build.zig build.zig.zon src examples
zig build test
zig build
zig build run
```

Tests live at the bottom of their source files. Commit messages follow
[Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/):

```text
<type>[optional scope]: <English description> / <Chinese description>
```

Commit bodies are also bilingual and start after one blank line.

## License

Licensed under the [MIT License (Expat)](LICENSE), the same license used by
[Zig](https://github.com/ziglang/zig/blob/master/LICENSE).
