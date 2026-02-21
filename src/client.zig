const std = @import("std");
const common = @import("common.zig");

pub fn sendCommand(allocator: std.mem.Allocator, args: []const []u8) !void {
    const addr = try std.net.Address.initUnix(common.SOCKET_PATH);
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    try std.posix.connect(fd, &addr.any, @sizeOf(std.posix.sockaddr.un));

    var stream = std.net.Stream{ .handle = fd };
    defer stream.close();

    const cmd = try std.mem.join(allocator, " ", args[1..]);
    defer allocator.free(cmd);

    try stream.writeAll(cmd);
    var res_buf: [256]u8 = undefined;
    const n = try stream.read(&res_buf);
    if (n > 0) std.debug.print("{s}", .{res_buf[0..n]});
}

pub fn showInfo() !void {
    const addr = std.net.Address.initUnix(common.SOCKET_PATH) catch return showOffline();
    const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch return showOffline();
    std.posix.connect(fd, &addr.any, @sizeOf(std.posix.sockaddr.un)) catch {
        std.posix.close(fd);
        return showOffline();
    };
    var stream = std.net.Stream{ .handle = fd };
    defer stream.close();

    try stream.writeAll("status");
    var buf: [256]u8 = undefined;
    const n = try stream.read(&buf);
    std.debug.print("--- HP Victus Status (Active) ---\n{s}", .{buf[0..n]});
}

fn showOffline() !void {
    const temp = common.getTemp(common.TEMP_PATH) catch 0;
    std.debug.print("--- HP Victus Status (Daemon Offline) ---\n", .{});
    std.debug.print("Temp: {d:.1}C\nRun 'sudo coolcontrol daemon' to start.\n", .{@as(f32, @floatFromInt(temp)) / 1000.0});
}
