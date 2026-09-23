const std = @import("std");
const common = @import("common.zig");
const net = std.Io.net;

pub fn sendCommand(io: std.Io, allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    _ = allocator;
    const ua = try net.UnixAddress.init(common.SOCKET_PATH);
    var stream = try ua.connect(io);
    defer stream.close(io);

    var wbuf: [512]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    // join args[1..] with spaces
    for (args[1..], 0..) |a, i| {
        if (i > 0) try w.interface.writeAll(" ");
        try w.interface.writeAll(a);
    }
    try w.interface.flush();

    var rbuf: [256]u8 = undefined;
    var r = stream.reader(io, &.{});
    const n = try r.interface.readSliceShort(&rbuf);
    if (n > 0) std.debug.print("{s}", .{rbuf[0..n]});
}

pub fn showInfo(io: std.Io) !void {
    const ua = net.UnixAddress.init(common.SOCKET_PATH) catch return showOffline(io);
    var stream = ua.connect(io) catch return showOffline(io);
    defer stream.close(io);

    var wbuf: [64]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    w.interface.writeAll("status") catch return showOffline(io);
    w.interface.flush() catch return showOffline(io);

    var buf: [256]u8 = undefined;
    var r = stream.reader(io, &.{});
    const n = r.interface.readSliceShort(&buf) catch return showOffline(io);
    std.debug.print("--- HP Victus Status (Active) ---\n{s}", .{buf[0..n]});
}

fn showOffline(io: std.Io) !void {
    const temp = common.getTemp(io, common.TEMP_PATH) catch 0;
    std.debug.print("--- HP Victus Status (Daemon Offline) ---\n", .{});
    std.debug.print("Temp: {d:.1}C\nRun 'sudo coolcontrol daemon' to start.\n", .{@as(f32, @floatFromInt(temp)) / 1000.0});
}
