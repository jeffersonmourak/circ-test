const std = @import("std");
const circ = @import("circ_test");
const build_options = @import("build_options");

fn loadCircuit(name: []const u8) !circ.Dut {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ build_options.circuits_dir, name });
    return circ.Dut.load(std.testing.allocator, path);
}

test "and gate: exhaustive a & b" {
    var dut = try loadCircuit("and.circ");
    defer dut.close();
    var a: u64 = 0;
    while (a <= 1) : (a += 1) {
        var b: u64 = 0;
        while (b <= 1) : (b += 1) {
            try dut.set("a", a);
            try dut.set("b", b);
            try dut.settle();
            try std.testing.expectEqual(a & b, try dut.getInt("out"));
        }
    }
}

test "full adder: sum and carry, computed reference" {
    var dut = try loadCircuit("full_adder.circ");
    defer dut.close();
    var a: u64 = 0;
    while (a <= 1) : (a += 1) {
        var b: u64 = 0;
        while (b <= 1) : (b += 1) {
            var cin: u64 = 0;
            while (cin <= 1) : (cin += 1) {
                try dut.set("a", a);
                try dut.set("b", b);
                try dut.set("cin", cin);
                try dut.settle();
                const total = a + b + cin;
                try std.testing.expectEqual(total & 1, try dut.getInt("sum"));
                try std.testing.expectEqual(total >> 1, try dut.getInt("cout"));
            }
        }
    }
}

test "undefined input propagates to undefined output" {
    var dut = try loadCircuit("and.circ");
    defer dut.close();
    try dut.setUndefined("a");
    try dut.set("b", 1);
    try dut.settle();
    try std.testing.expect(try dut.isUndefined("out"));
}
