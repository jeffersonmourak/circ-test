# circ-test

A behavioral test harness for [`circ-compiler`](../circ-compiler) circuits. You
write expectations for a `.circ` circuit in your own language's test runner, and
they run against the real compiled circuit.

It works by spawning `circ-compile <circuit>.circ --sim`, the compiler's
stdio drive protocol (`proto=1`), and driving the circuit by pin name:

```
  your test (node:test / vitest / zig test / ...)
        |   load / set / settle / get / eval
        v
  circ-test binding  --spawn-->  circ-compile <circuit> --sim
        ^                              |  (native simulation engine)
        +------- replies <-- stdio ----+
```

The **protocol is the contract**; the bindings are interchangeable reference
implementations of it. Two ship here (TypeScript and Zig), and any language
that can spawn a process and read/write lines can implement another, see
[`docs/writing-a-binding.md`](docs/writing-a-binding.md).

## Prerequisites

- `circ-compile` on your `PATH`, or point `CIRC_COMPILE_BIN` at the binary.
- TypeScript binding: Bun >= 1.0 or Node >= 22. No runtime dependencies.
- Zig binding: Zig 0.15.x.

## Layout

```
circuits/              shared example .circ files (and.circ, full_adder.circ)
ts/                    TypeScript binding + bun:test examples
zig/src/               Zig binding + std.testing examples
docs/writing-a-binding.md   how to implement a binding in a new language
```

## TypeScript

**Install:**

```sh
bun add circ-test
# or
npm install circ-test
```

**Use in your tests:**

```ts
import { test, expect } from "bun:test";
import { load } from "circ-test";

test("and gate", async () => {
  const dut = await load("circuits/and.circ");
  try {
    await dut.set("a", 1);
    await dut.set("b", 1);
    await dut.settle();
    expect(await dut.getInt("out")).toBe(1n);
  } finally {
    await dut.close();
  }
});
```

Works with any test runner (bun:test, vitest, node:test). The binding has no test-runner dependency.

**Run the bundled examples:**

```sh
cd ts
bun test                            # add CIRC_COMPILE_BIN=... if not on PATH
```

## Zig

**Install:**

```sh
zig fetch --save https://github.com/jeffersonmourak/circ-test/archive/refs/tags/v0.0.2.tar.gz
```

Add the module to your `build.zig`:

```zig
const circ_test = b.dependency("circ_test", .{
    .target = target,
    .optimize = optimize,
});
your_module.addImport("circ_test", circ_test.module("circ_test"));
```

**Use in your tests:**

```zig
const std = @import("std");
const circ = @import("circ_test");

test "and gate" {
    var dut = try circ.Dut.load(std.testing.allocator, "circuits/and.circ");
    defer dut.close();
    try dut.set("a", 1);
    try dut.set("b", 1);
    try dut.settle();
    try std.testing.expectEqual(@as(u64, 1), try dut.getInt("out"));
}
```

**Run the bundled examples:**

```sh
zig build test                      # add CIRC_COMPILE_BIN=... if not on PATH
```

## Finding `circ-compile`

Both bindings resolve the compiler the same way: the `CIRC_COMPILE_BIN`
environment variable if set, otherwise `circ-compile` on `PATH`. Pointing
`CIRC_COMPILE_BIN` at a local build is the usual way to test against an
unreleased compiler.

## Protocol

The wire protocol (`proto=1`) is specified in the compiler repo at
`DOCS/sim-protocol.md`. Each binding checks the `proto` version in the
handshake and refuses a mismatch, so a binding and a compiler that drift apart
fail loudly at startup rather than silently misbehaving.

## License

This project is licensed under the GNU General Public License v3.0 or later.
See the [LICENSE](LICENSE) file for the full text.
