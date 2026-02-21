const std = @import("std");

pub const SOCKET_PATH = "/tmp/coolcontrol.sock";
pub const PID_PATH = "/var/run/coolcontrol.pid";
pub const DEFAULT_CONFIG_PATH = "/etc/coolcontrol.json";

pub const Mode = enum { auto, manual, override };

pub const FanPoint = struct {
    temp: f32,
    speed: u8,
};

pub const Config = struct {
    ec_path: []const u8 = "/sys/kernel/debug/ec/ec0/io",
    temp_path: []const u8 = "/sys/class/thermal/thermal_zone0/temp",
    fan_addresses: []const u8 = &[_]u8{ 0x2C, 0x2D },
    critical_temp: f32 = 85.0,
    fan_curve: []const FanPoint = &[_]FanPoint{},

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Config) {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const size = try file.getEndPos();
        const buffer = try allocator.alloc(u8, size);
        defer allocator.free(buffer);
        const amt = try file.readAll(buffer);
        
        return std.json.parseFromSlice(Config, allocator, buffer[0..amt], .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }
};

pub fn getTemp(path: []const u8) !i32 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var buf: [32]u8 = undefined;
    const amt = try file.readAll(&buf);
    const trimmed = std.mem.trim(u8, buf[0..amt], " \n\r\t");
    return std.fmt.parseInt(i32, trimmed, 10);
}

pub const EC_PATH = "/sys/kernel/debug/ec/ec0/io";
pub const TEMP_PATH = "/sys/class/thermal/thermal_zone0/temp";
