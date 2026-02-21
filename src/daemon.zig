const std = @import("std");
const common = @import("common.zig");
const fs = std.fs;
const net = std.net;
const posix = std.posix;

var current_mode: common.Mode = .auto;
var manual_speeds: [8]u8 = [_]u8{0xFF} ** 8;
var safety_triggered: bool = false;
var should_run = true;
var global_config: ?common.Config = null;

fn sigHandler(_: i32) callconv(.c) void {
    should_run = false;
}

pub fn start(allocator: std.mem.Allocator, config_path: []const u8) !void {
    // Try to load config from provided path or fall back to built-in defaults
    var parsed_config = common.Config.load(allocator, config_path) catch |err| {
        std.debug.print("Notice: Could not load config from {s}: {}. Using default settings.\n", .{ config_path, err });
        // Create an "empty" config which will use default values
        const default_conf = common.Config{};
        global_config = default_conf;
        return run(allocator);
    };
    defer parsed_config.deinit();
    global_config = parsed_config.value;

    return run(allocator);
}

fn run(allocator: std.mem.Allocator) !void {
    _ = allocator; // For now
    if (std.fs.cwd().openFile(common.PID_PATH, .{})) |file| {
        var buf: [16]u8 = undefined;
        const amt = file.readAll(&buf) catch 0;
        file.close();

        if (amt > 0) {
            const old_pid = std.fmt.parseInt(i32, std.mem.trim(u8, buf[0..amt], " \n\r"), 10) catch 0;
            if (std.posix.kill(old_pid, 0)) |_| {
                std.debug.print("Error: Daemon already running (PID {d}).\n", .{old_pid});
                return;
            } else |_| {
                std.debug.print("Found stale PID file, cleaning up...\n", .{});
                std.fs.cwd().deleteFile(common.PID_PATH) catch {};
            }
        }
    } else |_| {}

    var pid_file = try std.fs.cwd().createFile(common.PID_PATH, .{});
    defer pid_file.close();

    var pid_buf: [16]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "{d}", .{std.os.linux.getpid()});
    try pid_file.writeAll(pid_str);

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
    std.debug.print("\nCleaning up and exiting...\n", .{});

    if (global_config) |cfg| {
        const ec_file = std.fs.cwd().openFile(cfg.ec_path, .{ .mode = .read_write }) catch return;
        defer ec_file.close();
        setFans(ec_file, cfg.fan_addresses, &[_]u8{0xFF} ** 8) catch {};
    }

    std.fs.cwd().deleteFile(common.SOCKET_PATH) catch {};
    std.fs.cwd().deleteFile(common.PID_PATH) catch {};

    std.debug.print("Goodbye!\n", .{});
}

fn runLoop() !void {
    const cfg = global_config orelse return error.ConfigNotLoaded;
    const ec_file = try std.fs.cwd().openFile(cfg.ec_path, .{ .mode = .read_write });
    defer ec_file.close();

    std.fs.cwd().deleteFile(common.SOCKET_PATH) catch {};
    var server_addr = try net.Address.initUnix(common.SOCKET_PATH);
    var listener = try server_addr.listen(.{ .reuse_address = true });
    
    // Set listener to non-blocking
    const flags = try posix.fcntl(listener.stream.handle, posix.F.GETFL, 0);
    _ = try posix.fcntl(listener.stream.handle, posix.F.SETFL, flags | 2048);
    _ = std.os.linux.chmod(common.SOCKET_PATH, 0o666);

    std.debug.print("Daemon is running. Config loaded: EC={s}, Temp={s}\n", .{cfg.ec_path, cfg.temp_path});

    var poll_fds = [_]posix.pollfd{
        .{ .fd = listener.stream.handle, .events = posix.POLL.IN, .revents = 0 },
    };

    while (should_run) {
        try updateHardwareState(ec_file, cfg);

        const poll_ret = posix.poll(&poll_fds, 1000) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };

        if (poll_ret > 0 and (poll_fds[0].revents & posix.POLL.IN) != 0) {
            handleCommands(&listener, ec_file, cfg) catch |err| {
                if (err != error.WouldBlock) {
                    std.debug.print("Command handling error: {}\n", .{err});
                }
            };
        }
    }
}

fn calculateCurveSpeed(temp_c: f32, curve: []const common.FanPoint) u8 {
    if (curve.len == 0) return 0xFF; // Auto
    if (temp_c < curve[0].temp) return curve[0].speed;
    
    for (0..curve.len - 1) |i| {
        const p1 = curve[i];
        const p2 = curve[i+1];
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

fn updateHardwareState(ec_file: fs.File, cfg: common.Config) !void {
    const temp = try common.getTemp(cfg.temp_path);
    const temp_c = @as(f32, @floatFromInt(temp)) / 1000.0;
    const now = std.time.timestamp();

    if (temp_c > cfg.critical_temp) {
        if (!safety_triggered) {
            std.debug.print("CRITICAL TEMP: {d:.1}C! Forcing Max Fans.\n", .{temp_c});
            safety_triggered = true;
        }
        const max_buf = [_]u8{0xFE} ** 8;
        try setFans(ec_file, cfg.fan_addresses, &max_buf);
    } else {
        if (safety_triggered) {
            std.debug.print("Temp stabilized: {d:.1}C. Returning to {s} mode.\n", .{ temp_c, @tagName(current_mode) });
            safety_triggered = false;
        }
        
        var target_speeds: [8]u8 = undefined;
        switch (current_mode) {
            .auto => {
                const s = calculateCurveSpeed(temp_c, cfg.fan_curve);
                @memset(&target_speeds, s);
            },
            .manual => {
                target_speeds = manual_speeds;
            },
            .override => return,
        }

        if (now - last_log_time >= 5) {
            std.debug.print("[Monitor] Temp: {d:.1}C, Mode: {s}, Fans: ", .{ temp_c, @tagName(current_mode) });
            for (0..cfg.fan_addresses.len) |i| {
                std.debug.print("#{d}: {d} ", .{ i, target_speeds[i] });
            }
            std.debug.print("\n", .{});
            last_log_time = now;
        }

        try setFans(ec_file, cfg.fan_addresses, &target_speeds);
    }
}

fn handleCommands(listener: *net.Server, ec_file: fs.File, cfg: common.Config) !void {
    var conn = listener.accept() catch |err| {
        if (err == error.WouldBlock) return;
        return err;
    };
    defer conn.stream.close();

    var buf: [128]u8 = undefined;
    const n = try conn.stream.read(&buf);
    if (n == 0) return;
    const msg = std.mem.trim(u8, buf[0..n], " \n\r\t");
    
    // Debug log
    std.debug.print("[Command] Received: '{s}'\n", .{msg});

    var res_buf: [256]u8 = undefined;

    if (std.mem.eql(u8, msg, "status")) {
        const temp = try common.getTemp(cfg.temp_path);
        const temp_f = @as(f32, @floatFromInt(temp)) / 1000.0;
        
        const response = try std.fmt.bufPrint(&res_buf, 
            "Temp: {d:.1}C\nMode: {s}\nSafety: {s}\n", .{ 
            temp_f, 
            @tagName(current_mode), 
            if (safety_triggered) "ACTIVE" else "OK" 
        });
        try conn.stream.writeAll(response);

        for (0..cfg.fan_addresses.len) |i| {
            const speed = if (current_mode == .manual) 
                manual_speeds[i] 
            else 
                calculateCurveSpeed(temp_f, cfg.fan_curve);
            
            const fan_info = try std.fmt.bufPrint(&res_buf, "Fan #{d} (addr 0x{X:0>2}): {d}\n", .{ i, cfg.fan_addresses[i], speed });
            try conn.stream.writeAll(fan_info);
        }
    } else if (std.mem.startsWith(u8, msg, "set ")) {
        if (safety_triggered) {
            try conn.stream.writeAll("REJECTED: Safety Override Active\n");
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
                // If only one value was provided, apply it to all 8 slots
                for (0..8) |idx| manual_speeds[idx] = last_val;
                std.debug.print("[Command] Set all fans to {d}\n", .{last_val});
            } else {
                std.debug.print("[Command] Set {d} individual fan speeds\n", .{i});
            }

            current_mode = .manual;
            try updateHardwareState(ec_file, cfg); // Force update immediately
            try conn.stream.writeAll("OK\n");
        }
    } else if (std.mem.eql(u8, msg, "auto")) {
        current_mode = .auto;
        try updateHardwareState(ec_file, cfg);
        try conn.stream.writeAll("OK: Auto Mode\n");
    }
}

fn setFans(file: fs.File, addresses: []const u8, values: []const u8) !void {
    for (addresses, 0..) |addr, i| {
        const buf = [_]u8{values[i]};
        _ = try std.posix.pwrite(file.handle, &buf, addr);
    }
}


