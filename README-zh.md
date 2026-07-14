# zepoch

<p align="center">
  <img src="assets/logo.png" alt="zepoch 标志" width="480">
</p>

[English](README.md)

`zepoch` 是面向 Zig 0.17.0-dev.1387+01b60634c 的显式时间库。它把绝对时间、
墙上时间、固定偏移视图和单调时间拆成不同类型，并通过 Zig 0.17 的 `std.Io`、
`std.Tz` 接入系统能力。库不会猜测时区、读取全局环境或隐藏分配。

## 时间模型

| 类型 | 含义 | 允许的操作 |
| --- | --- | --- |
| `Instant` | 忽略闰秒的 POSIX/Unix 绝对时间点 | 时间戳转换、精确时长运算、排序 |
| `LocalDateTime` | 无时区的墙上时间 | 公历校验、星期、年内日、日期算术 |
| `OffsetDateTime` | `Instant` 加显式固定 UTC 偏移 | RFC 3339、固定偏移日历视图 |
| `MonotonicInstant` | `awake` 或 `boot` 单调时钟读数 | 超时和耗时测量 |
| `TzifZone` | 调用方提供的 IANA TZif 转换规则 | 瞬间转本地时间、DST 缺口与折叠解析 |

这些类型之间不做隐式转换。`Instant` 不保存展示偏移，`LocalDateTime` 不假定
本机时区，`MonotonicInstant` 不能格式化为日期。所有方法返回新值，不原地修改
时间对象。

## 设计规则

- `Instant.now(io)` 和 `MonotonicInstant.now(io, clock)` 显式接收 `std.Io`。
- `TzifZone.parse(allocator, identifier, bytes)` 显式接收分配器、IANA 标识符和
  TZif 字节；标识符及字节如何取得由调用方决定。
- 格式化写入调用方提供的 `*std.Io.Writer`，不分配返回字符串。
- 非法日期、非法偏移、精度损失和算术溢出直接返回错误，不归一化或回退。
- 月份运算必须选择 `.reject`、`.clamp` 或 `.preserve_end_of_month`。
- `LocalDateTime.addDays` 移动日历日期并保留墙上时钟字段；它不是
  `Duration.fromHours(24)`，也不会暗示跨 DST 的经过时长。
- 时区缩写只作为 TZif 展示信息返回。查找键必须使用 `Asia/Shanghai`、
  `America/New_York`、`Etc/UTC` 等带区域的 IANA 标识符。

## POSIX 时间与闰秒

`Instant.now(io)` 读取 `std.Io.Clock.now(.real, io).nanoseconds`，再规范化为
`i64 unix_seconds` 和 `[0, 1_000_000_000)` 范围的 `u32 nanosecond`。负值使用
floor 除法与非负余数，因此 `-1 ns` 表示为 `-1 s + 999_999_999 ns`。

`Instant` 与 Zig `std.Io.Clock.real` 保持一致：使用 Unix 纪元并忽略闰秒。
`2016-12-31T23:59:60Z` 返回 `error.InvalidSecond`，不会被隐式归一化。
`TzifZone.leapSecondRecords()` 可以访问 TZif 携带的闰秒记录，但不会把记录应用
到 POSIX 时间。TAI、GPS、UT1 或天文历书需要独立时间尺度和权威闰秒表。

## 历法与 TZif 边界

`LocalDateTime` 使用预推格里高利历和 ISO 8601 年份编号，包含公元 0 年。
它不模拟 1582 年儒略历切换；需要历史切换日期的程序必须显式选择其他历法。

`TzifZone` 委托 Zig 标准库解析 RFC 8536 TZif，不维护自己的 tzdb。为避免忽略
TZif footer 中的未来 POSIX 规则，当前只在两个相邻转换点之间提供结果：

- `.unique`：唯一绝对时间点；
- `.ambiguous`：秋季折叠产生的两个时间点；
- `.nonexistent`：春季跳时或日期线调整产生的本地时间缺口；
- `.outside_coverage`：TZif 转换表无法证明结果。

## 精度与格式

`Instant` 使用 `i64` 秒加 `u32` 纳秒；`Duration` 使用有符号 `i128` 纳秒。
时间戳从不使用浮点数。`Duration` 不提供 `fromDays`，需要精确 24 小时时应写
`Duration.fromHours(24)`。

`parse.rfc3339` 接受四位年份、`T`、秒、可选 1—9 位小数及 `Z` 或
`±HH:MM`。无效日期不会宽松归一化。`-00:00` 返回
`error.UnknownLocalOffset`。RFC 3339 无法表达带秒的历史 UTC 偏移，格式化时
会返回 `error.OffsetPrecisionLoss`。

本库不包含月份／星期翻译、12 小时制或地区化周规则。这些策略属于调用方选择
的本地化层。

## 安装

```bash
zig fetch --save https://github.com/GuangYiL/zepoch/archive/refs/heads/zig-0.17.tar.gz
```

```zig
const dependency = build_system.dependency("zepoch", .{
    .target = target,
    .optimize = optimize,
});
executable.root_module.addImport("zepoch", dependency.module("zepoch"));
```

## 使用

```zig
const std = @import("std");
const zepoch = @import("zepoch");

pub fn main(init: std.process.Init) !void {
    const now = try zepoch.Instant.now(init.io);
    const utc_plus_eight = zepoch.OffsetDateTime{
        .instant = now,
        .offset = try zepoch.UtcOffset.fromSeconds(8 * 3_600),
    };

    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try zepoch.format.writeRfc3339(utc_plus_eight, &writer);
}
```

命名时区由调用方负责取得并缓存 TZif 数据：

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

## 开发与提交

`zig-0.17` 分支要求 `PATH` 中的 Zig 版本为 `0.17.0-dev.1387+01b60634c`：

```bash
zig fmt --check build.zig build.zig.zon src examples
zig build test
zig build
zig build run
```

测试与目标代码放在同一源文件底部。提交信息遵循
[约定式提交 1.0.0](https://www.conventionalcommits.org/zh-hans/v1.0.0/)：

```text
<type>[optional scope]: <English description> / <中文描述>
```

提交正文同样使用英文和中文，并与标题之间保留一个空行。

## 许可证

本项目采用 [MIT License (Expat)](LICENSE)，与
[Zig](https://github.com/ziglang/zig/blob/master/LICENSE) 使用相同许可证。
