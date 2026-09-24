const std = @import("std");

pub const SOCKET_PATH = "/tmp/coolcontrol.sock";
pub const PID_PATH = "/var/run/coolcontrol.pid";
pub const DEFAULT_CONFIG_PATH = "/etc/coolcontrol.json";

pub const Mode = enum { auto, manual, override };

pub const FanPoint = struct {
    temp: f32,
    speed: u8,
};

pub const Smoothing = struct {
    ema_alpha: f32 = 0.3,
    max_step_up: u8 = 6,
    max_step_down: u8 = 8,
    min_step: u8 = 2,
    hysteresis_temp: f32 = 1.5,
    hysteresis_delay_s: i64 = 3,
    only_downward: bool = true,
};

pub const Config = struct {
    ec_path: []const u8 = "/sys/kernel/debug/ec/ec0/io",
    temp_path: []const u8 = "/sys/class/thermal/thermal_zone0/temp",
    fan_addresses: []const u8 = &[_]u8{ 44, 45 },
    critical_temp: f32 = 92.0,
    fan_curve: []const FanPoint = &[_]FanPoint{
        .{ .temp = 45.0, .speed = 50 },
        .{ .temp = 60.0, .speed = 90 },
        .{ .temp = 75.0, .speed = 160 },
        .{ .temp = 85.0, .speed = 210 },
        .{ .temp = 92.0, .speed = 254 },
    },
    smoothing: Smoothing = .{},

    pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Config) {
        var file = try openFile(io, path, .{});
        defer file.close(io);
        const len = try file.length(io);
        const size: usize = @intCast(len);
        const buffer = try allocator.alloc(u8, size);
        defer allocator.free(buffer);
        var r = file.reader(io, &.{});
        try r.interface.readSliceAll(buffer);
        return std.json.parseFromSlice(Config, allocator, buffer, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }
};

pub fn getTemp(io: std.Io, path: []const u8) !i32 {
    var file = try openFile(io, path, .{});
    defer file.close(io);
    var buf: [32]u8 = undefined;
    var r = file.reader(io, &.{});
    const n = try r.interface.readSliceShort(&buf);
    const trimmed = std.mem.trim(u8, buf[0..n], " \n\r\t");
    return std.fmt.parseInt(i32, trimmed, 10);
}

pub const EC_PATH = "/sys/kernel/debug/ec/ec0/io";
pub const TEMP_PATH = "/sys/class/thermal/thermal_zone0/temp";

/// openFileAbsolute asserts on relative paths, so route everything here.
pub fn openFile(io: std.Io, path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
    if (std.Io.Dir.path.isAbsolute(path)) {
        return std.Io.Dir.openFileAbsolute(io, path, options);
    }
    return std.Io.Dir.cwd().openFile(io, path, options);
}

pub fn createFile(io: std.Io, path: []const u8, flags: std.Io.Dir.CreateFileOptions) std.Io.File.OpenError!std.Io.File {
    if (std.Io.Dir.path.isAbsolute(path)) {
        return std.Io.Dir.createFileAbsolute(io, path, flags);
    }
    return std.Io.Dir.cwd().createFile(io, path, flags);
}
