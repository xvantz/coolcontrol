const std = @import("std");
const common = @import("common.zig");
const posix = std.posix;
const net = std.Io.net;

var current_mode: common.Mode = .auto;
var manual_speeds: [8]u8 = [_]u8{0xFF} ** 8;
var safety_triggered: bool = false;
var should_run = true;
var global_config: ?common.Config = null;
var global_io: std.Io = undefined;

// Smoothing state (EMA + hysteresis + slew-limit)
var ema_temp: ?f32 = null;
var current_speed: ?u8 = null;
var last_change_ts: i64 = 0;
var last_applied_temp: ?f32 = null;

fn sigHandler(_: posix.SIG) callconv(.c) void {
    should_run = false;
}

pub fn start(io: std.Io, allocator: std.mem.Allocator, config_path: []const u8) !void {
    global_io = io;
    var parsed_config = common.Config.load(io, allocator, config_path) catch |err| {
        std.debug.print("Notice: Could not load config from {s}: {}. Using default settings.\n", .{ config_path, err });
        const default_conf = common.Config{};
        global_config = default_conf;
        return run(allocator);
    };
    defer parsed_config.deinit();
    global_config = parsed_config.value;

    return run(allocator);
}

fn nowSec(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

fn run(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const io = global_io;

    // PID file check
    if (common.openFile(io, common.PID_PATH, .{})) |file| {
        var f = file;
        defer f.close(io);
        var buf: [16]u8 = undefined;
        var r = f.reader(io, &.{});
        const n = r.interface.readSliceShort(&buf) catch 0;
        if (n > 0) {
            const old_pid = std.fmt.parseInt(i32, std.mem.trim(u8, buf[0..n], " \n\r"), 10) catch 0;
            if (old_pid != 0) {
                if (posix.kill(old_pid, @enumFromInt(0))) {
                    std.debug.print("Error: Daemon already running (PID {d}).\n", .{old_pid});
                    return;
                } else |_| {
                    std.debug.print("Found stale PID file, cleaning up...\n", .{});
                    std.Io.Dir.deleteFileAbsolute(io, common.PID_PATH) catch {};
                }
            }
        }
    } else |_| {}

    {
        var pid_file = try common.createFile(io, common.PID_PATH, .{});
        defer pid_file.close(io);
        var pid_buf: [16]u8 = undefined;
        const pid_str = try std.fmt.bufPrint(&pid_buf, "{d}", .{std.os.linux.getpid()});
        var w = pid_file.writer(io, &.{});
        try w.interface.writeAll(pid_str);
    }

    var act = posix.Sigaction{
        .handler = .{ .handler = sigHandler },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    runLoop() catch |err| {
        std.debug.print("Daemon crashed with error: {}\n", .{err});
    };

    cleanup();
}

fn cleanup() void {
    const io = global_io;
    std.debug.print("\nCleaning up and exiting...\n", .{});

    if (global_config) |cfg| {
        if (common.openFile(io, cfg.ec_path, .{ .mode = .read_write })) |file| {
            var f = file;
            defer f.close(io);
            const off: [8]u8 = [_]u8{0xFF} ** 8;
            setFans(f, cfg.fan_addresses, &off) catch {};
        } else |_| {}
    }

    std.Io.Dir.deleteFileAbsolute(io, common.SOCKET_PATH) catch {};
    std.Io.Dir.deleteFileAbsolute(io, common.PID_PATH) catch {};

    std.debug.print("Goodbye!\n", .{});
}

fn runLoop() !void {
    const cfg = global_config orelse return error.ConfigNotLoaded;
    const io = global_io;
    var ec_file = try common.openFile(io, cfg.ec_path, .{ .mode = .read_write });
    defer ec_file.close(io);

    std.Io.Dir.deleteFileAbsolute(io, common.SOCKET_PATH) catch {};
    const ua = try net.UnixAddress.init(common.SOCKET_PATH);
    var server = try ua.listen(io, .{});
    defer server.deinit(io);

    std.debug.print("Daemon is running. Config loaded: EC={s}, Temp={s}\n", .{ cfg.ec_path, cfg.temp_path });

    var poll_fds = [_]posix.pollfd{
        .{ .fd = server.socket.handle, .events = posix.POLL.IN, .revents = 0 },
    };

    while (should_run) {
        try updateHardwareState(ec_file, cfg);

        const poll_ret = posix.poll(&poll_fds, 1000) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };

        if (poll_ret > 0 and (poll_fds[0].revents & posix.POLL.IN) != 0) {
            handleCommands(&server, ec_file, cfg) catch |err| {
                if (err != error.WouldBlock and err != error.ConnectionAborted) {
                    std.debug.print("Command handling error: {}\n", .{err});
                }
            };
        }
        poll_fds[0].revents = 0;
    }
}

fn calculateCurveSpeed(temp_c: f32, curve: []const common.FanPoint) u8 {
    if (curve.len == 0) return 0xFF;
    if (temp_c < curve[0].temp) return curve[0].speed;

    for (0..curve.len - 1) |i| {
        const p1 = curve[i];
        const p2 = curve[i + 1];
        if (temp_c >= p1.temp and temp_c <= p2.temp) {
            const ratio = (temp_c - p1.temp) / (p2.temp - p1.temp);
            const s1: f32 = @floatFromInt(p1.speed);
            const s2: f32 = @floatFromInt(p2.speed);
            const speed_f = s1 + ratio * (s2 - s1);
            return @intFromFloat(speed_f);
        }
    }

    return curve[curve.len - 1].speed;
}

var last_log_time: i64 = 0;

fn applyEma(raw: f32, alpha: f32) f32 {
    if (ema_temp) |prev| {
        const v = alpha * raw + (1.0 - alpha) * prev;
        ema_temp = v;
        return v;
    } else {
        ema_temp = raw;
        return raw;
    }
}

fn applySmoothing(target: u8, ema: f32, now: i64, sm: common.Smoothing) u8 {
    const cur = current_speed orelse {
        current_speed = target;
        last_change_ts = now;
        last_applied_temp = ema;
        return target;
    };
    if (target == cur) return cur;

    if (sm.only_downward and target < cur) {
        const last_t = last_applied_temp orelse ema;
        const temp_drop = last_t - ema;
        const dt = now - last_change_ts;
        if (temp_drop < sm.hysteresis_temp and dt < sm.hysteresis_delay_s) {
            return cur;
        }
    }

    if (target > cur) {
        const delta: u16 = @as(u16, target) - @as(u16, cur);
        if (delta < sm.min_step) return cur;
        const step: u8 = @intCast(@min(delta, @as(u16, sm.max_step_up)));
        const next: u8 = cur + step;
        current_speed = next;
        last_change_ts = now;
        last_applied_temp = ema;
        return next;
    } else {
        const delta: u16 = @as(u16, cur) - @as(u16, target);
        if (delta < sm.min_step) return cur;
        const step: u8 = @intCast(@min(delta, @as(u16, sm.max_step_down)));
        const next: u8 = cur - step;
        current_speed = next;
        last_change_ts = now;
        last_applied_temp = ema;
        return next;
    }
}

fn updateHardwareState(ec_file: std.Io.File, cfg: common.Config) !void {
    const io = global_io;
    const temp = try common.getTemp(io, cfg.temp_path);
    const temp_c = @as(f32, @floatFromInt(temp)) / 1000.0;
    const now = nowSec(io);

    if (temp_c > cfg.critical_temp) {
        if (!safety_triggered) {
            std.debug.print("CRITICAL TEMP: {d:.1}C! Forcing Max Fans.\n", .{temp_c});
            safety_triggered = true;
        }
        ema_temp = temp_c;
        current_speed = 0xFE;
        last_change_ts = now;
        last_applied_temp = temp_c;
        const max_buf = [_]u8{0xFE} ** 8;
        try setFans(ec_file, cfg.fan_addresses, &max_buf);
    } else {
        if (safety_triggered) {
            std.debug.print("Temp stabilized: {d:.1}C. Returning to {s} mode.\n", .{ temp_c, @tagName(current_mode) });
            safety_triggered = false;
        }

        var target_speeds: [8]u8 = undefined;
        var log_target: u8 = 0;
        var log_applied: u8 = 0;
        switch (current_mode) {
            .auto => {
                const ema = applyEma(temp_c, cfg.smoothing.ema_alpha);
                const target = calculateCurveSpeed(ema, cfg.fan_curve);
                const applied = applySmoothing(target, ema, now, cfg.smoothing);
                @memset(&target_speeds, applied);
                log_target = target;
                log_applied = applied;
            },
            .manual => {
                target_speeds = manual_speeds;
                log_target = manual_speeds[0];
                log_applied = manual_speeds[0];
            },
            .override => return,
        }

        if (now - last_log_time >= 5) {
            const ema_show = ema_temp orelse temp_c;
            std.debug.print("[Monitor] Temp: {d:.1}C EMA: {d:.1}C target: {d} applied: {d} Mode: {s} Fans: ", .{ temp_c, ema_show, log_target, log_applied, @tagName(current_mode) });
            for (0..cfg.fan_addresses.len) |i| {
                std.debug.print("#{d}: {d} ", .{ i, target_speeds[i] });
            }
            std.debug.print("\n", .{});
            last_log_time = now;
        }

        try setFans(ec_file, cfg.fan_addresses, &target_speeds);
    }
}

fn handleCommands(server: *net.Server, ec_file: std.Io.File, cfg: common.Config) !void {
    const io = global_io;
    var conn = try server.accept(io);
    defer conn.close(io);

    var buf: [128]u8 = undefined;
    var r = conn.reader(io, &.{});
    const n = try r.interface.readSliceShort(&buf);
    if (n == 0) return;
    const msg = std.mem.trim(u8, buf[0..n], " \n\r\t");

    std.debug.print("[Command] Received: '{s}'\n", .{msg});

    var res_buf: [256]u8 = undefined;

    if (std.mem.eql(u8, msg, "status")) {
        const temp = try common.getTemp(io, cfg.temp_path);
        const temp_f = @as(f32, @floatFromInt(temp)) / 1000.0;

        var w = conn.writer(io, &.{});
        const response = try std.fmt.bufPrint(&res_buf, "Temp: {d:.1}C\nMode: {s}\nSafety: {s}\n", .{
            temp_f,
            @tagName(current_mode),
            if (safety_triggered) "ACTIVE" else "OK",
        });
        try w.interface.writeAll(response);

        for (0..cfg.fan_addresses.len) |i| {
            const speed = if (current_mode == .manual)
                manual_speeds[i]
            else
                calculateCurveSpeed(temp_f, cfg.fan_curve);

            const fan_info = try std.fmt.bufPrint(&res_buf, "Fan #{d} (addr 0x{X:0>2}): {d}\n", .{ i, cfg.fan_addresses[i], speed });
            try w.interface.writeAll(fan_info);
        }
        try w.interface.flush();
    } else if (std.mem.startsWith(u8, msg, "set ")) {
        var w = conn.writer(io, &.{});
        if (safety_triggered) {
            try w.interface.writeAll("REJECTED: Safety Override Active\n");
            try w.interface.flush();
        } else {
            var iter = std.mem.tokenizeAny(u8, msg[4..], " ,;");
            var i: usize = 0;
            var last_val: u8 = 255;

            while (iter.next()) |token| {
                if (i >= 8) break;
                const val = std.fmt.parseInt(u8, token, 10) catch continue;
                manual_speeds[i] = val;
                last_val = val;
                i += 1;
            }

            if (i == 1) {
                for (0..8) |idx| manual_speeds[idx] = last_val;
                std.debug.print("[Command] Set all fans to {d}\n", .{last_val});
            } else {
                std.debug.print("[Command] Set {d} individual fan speeds\n", .{i});
            }

            current_mode = .manual;
            try updateHardwareState(ec_file, cfg);
            try w.interface.writeAll("OK\n");
            try w.interface.flush();
        }
    } else if (std.mem.eql(u8, msg, "auto")) {
        current_mode = .auto;
        try updateHardwareState(ec_file, cfg);
        var w = conn.writer(io, &.{});
        try w.interface.writeAll("OK: Auto Mode\n");
        try w.interface.flush();
    }
}

fn setFans(file: std.Io.File, addresses: []const u8, values: []const u8) !void {
    const io = global_io;
    for (addresses, 0..) |addr, i| {
        const b = [_]u8{values[i]};
        try file.writePositionalAll(io, &b, addr);
    }
}
