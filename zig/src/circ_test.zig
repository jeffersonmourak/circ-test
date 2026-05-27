const std = @import("std");

/// Wire-protocol version this binding speaks (see DOCS/sim-protocol.md).
pub const PROTO_VERSION: u32 = 1;

pub const Dir = enum { in, out };
pub const PinInfo = struct { dir: Dir, width: u8 };

/// A pin reading: `value` with a per-bit `defined` mask (0 bits are undefined).
pub const Reading = struct { value: u64, defined: u64, width: u8 };

/// A circuit under test: one `circ-compile --sim` subprocess, driven by pin name.
/// The compiler binary is `$CIRC_COMPILE_BIN`, else `circ-compile` on PATH.
pub const Dut = struct {
    child: std.process.Child,
    arena: std.heap.ArenaAllocator,
    pins: std.StringHashMapUnmanaged(PinInfo),
    line_buf: [4096]u8 = undefined,
    cmd_buf: [4096]u8 = undefined,

    pub fn load(gpa: std.mem.Allocator, circuit_path: []const u8) !Dut {
        const bin_owned = std.process.getEnvVarOwned(gpa, "CIRC_COMPILE_BIN") catch null;
        defer if (bin_owned) |b| gpa.free(b);
        const exe = bin_owned orelse "circ-compile";

        var child = std.process.Child.init(&.{ exe, circuit_path, "--sim" }, gpa);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        errdefer _ = child.kill() catch {};

        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        var buf: [4096]u8 = undefined;
        var reader = child.stdout.?.deprecatedReader();

        const header = (try reader.readUntilDelimiterOrEof(&buf, '\n')) orelse return error.StreamClosed;
        if (std.mem.startsWith(u8, header, "error")) return error.CompileFailed;

        var it = std.mem.tokenizeScalar(u8, header, ' ');
        if (!std.mem.eql(u8, it.next() orelse "", "ready")) return error.BadHandshake;
        const proto = parseField(it.next(), "proto=") orelse return error.BadHandshake;
        if (proto != PROTO_VERSION) return error.UnsupportedProtocol;
        const pin_count = parseField(it.next(), "pins=") orelse return error.BadHandshake;
        const warn_count = parseField(it.next(), "warnings=") orelse return error.BadHandshake;

        var pins: std.StringHashMapUnmanaged(PinInfo) = .{};
        var i: usize = 0;
        while (i < pin_count) : (i += 1) {
            const line = (try reader.readUntilDelimiterOrEof(&buf, '\n')) orelse return error.BadHandshake;
            var pt = std.mem.tokenizeScalar(u8, line, ' ');
            _ = pt.next(); // "pin"
            const name = pt.next() orelse return error.BadHandshake;
            const dir_s = pt.next() orelse return error.BadHandshake;
            const width_s = pt.next() orelse return error.BadHandshake;
            try pins.put(a, try a.dupe(u8, name), .{
                .dir = if (std.mem.eql(u8, dir_s, "in")) .in else .out,
                .width = std.fmt.parseInt(u8, width_s, 10) catch return error.BadHandshake,
            });
        }
        var w: usize = 0;
        while (w < warn_count) : (w += 1) _ = try reader.readUntilDelimiterOrEof(&buf, '\n');

        return .{ .child = child, .arena = arena, .pins = pins };
    }

    fn readLine(self: *Dut) !?[]const u8 {
        return self.child.stdout.?.deprecatedReader().readUntilDelimiterOrEof(&self.line_buf, '\n');
    }

    fn cmd(self: *Dut, line: []const u8) ![]const u8 {
        try self.child.stdin.?.writeAll(line);
        try self.child.stdin.?.writeAll("\n");
        return (try self.readLine()) orelse error.StreamClosed;
    }

    fn cmdFmt(self: *Dut, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const line = try std.fmt.bufPrint(&self.cmd_buf, fmt, args);
        return self.cmd(line);
    }

    /// Drive a top-level input fully defined.
    pub fn set(self: *Dut, name: []const u8, value: u64) !void {
        const reply = try self.cmdFmt("set {s} {d}", .{ name, value });
        if (!std.mem.startsWith(u8, reply, "ok")) return error.CommandFailed;
    }

    /// Drive a top-level input with an explicit defined mask (0 bits are X).
    pub fn setMask(self: *Dut, name: []const u8, value: u64, mask: u64) !void {
        const reply = try self.cmdFmt("set {s} {d} {d}", .{ name, value, mask });
        if (!std.mem.startsWith(u8, reply, "ok")) return error.CommandFailed;
    }

    /// Drive `name` fully undefined (all bits X).
    pub fn setUndefined(self: *Dut, name: []const u8) !void {
        try self.setMask(name, 0, 0);
    }

    /// Settle the circuit (drains the event queue).
    pub fn settle(self: *Dut) !void {
        if (!std.mem.startsWith(u8, try self.cmd("run"), "ok")) return error.CommandFailed;
    }

    /// Reset to the post-init state (all pins undefined).
    pub fn reset(self: *Dut) !void {
        if (!std.mem.startsWith(u8, try self.cmd("reset"), "ok")) return error.CommandFailed;
    }

    /// Read a pin's current `(value, defined)`.
    pub fn get(self: *Dut, name: []const u8) !Reading {
        const reply = try self.cmdFmt("get {s}", .{name});
        if (!std.mem.startsWith(u8, reply, "ok ")) return error.CommandFailed;
        var it = std.mem.tokenizeScalar(u8, reply, ' ');
        _ = it.next(); // "ok"
        const v = it.next() orelse return error.CommandFailed;
        const d = it.next() orelse return error.CommandFailed;
        return .{
            .value = std.fmt.parseInt(u64, v, 0) catch return error.CommandFailed,
            .defined = std.fmt.parseInt(u64, d, 0) catch return error.CommandFailed,
            .width = (self.pins.get(name) orelse return error.NoSuchPin).width,
        };
    }

    /// Read a pin as an integer, erroring if any bit is undefined.
    pub fn getInt(self: *Dut, name: []const u8) !u64 {
        const r = try self.get(name);
        if (r.defined != fullMask(r.width)) return error.UndefinedBits;
        return r.value;
    }

    /// True if the pin is fully undefined.
    pub fn isUndefined(self: *Dut, name: []const u8) !bool {
        return (try self.get(name)).defined == 0;
    }

    /// End the session and reap the subprocess.
    pub fn close(self: *Dut) void {
        if (self.child.stdin) |stdin| {
            _ = stdin.writeAll("quit\n") catch {};
            stdin.close();
            self.child.stdin = null;
        }
        _ = self.child.wait() catch {};
        self.arena.deinit();
    }
};

fn parseField(tok: ?[]const u8, prefix: []const u8) ?u32 {
    const t = tok orelse return null;
    if (!std.mem.startsWith(u8, t, prefix)) return null;
    return std.fmt.parseInt(u32, t[prefix.len..], 10) catch null;
}

fn fullMask(width: u8) u64 {
    if (width >= 64) return std.math.maxInt(u64);
    return (@as(u64, 1) << @intCast(width)) - 1;
}
