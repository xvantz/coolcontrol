const std = @import("std");
const daemon = @import("daemon.zig");
const client = @import("client.zig");
const common = @import("common.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "daemon")) {
            var config_path: []const u8 = common.DEFAULT_CONFIG_PATH;
            for (args, 0..) |arg, i| {
                if ((std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) and i + 1 < args.len) {
                    config_path = args[i + 1];
                    break;
                }
            }
            try checkPrivileges();
            try daemon.start(allocator, config_path);
        } else {
            client.sendCommand(allocator, args) catch |err| {
                if (err == error.ConnectionRefused) {
                    std.debug.print("Error: Daemon not running.\n", .{});
                } else return err;
            };
        }
    } else {
        try client.showInfo();
    }
}

fn checkPrivileges() !void {
    const file = std.fs.cwd().openFile(common.EC_PATH, .{ .mode = .read_write }) catch |err| {
        if (err == error.AccessDenied) {
            std.debug.print("Error: Access Denied. Please run with 'sudo'.\n", .{});
        } else if (err == error.FileNotFound) {
            std.debug.print("Error: EC device not found. Try: 'sudo modprobe ec_sys'\n", .{});
        } else {
            std.debug.print("Error opening EC: {}\n", .{err});
        }
        std.process.exit(1);
    };
    defer file.close();
    const test_val = [_]u8{0xFF};
    _ = std.posix.pwrite(file.handle, &test_val, 0x2C) catch |err| {
        if (err == error.InvalidArgument) {
            std.debug.print(
                \\-------------------------------------------------------
                \\CRITICAL ERROR: EC Write Support is DISABLED!
                \\The driver is in Read-Only mode.
                \\
                \\To fix this, run:
                \\sudo modprobe -r ec_sys && sudo modprobe ec_sys write_support=1
                \\-------------------------------------------------------
                \\
            , .{});
        } else {
            std.debug.print("EC Probe Failed: {}\n", .{err});
        }
        std.process.exit(1);
    };
}
