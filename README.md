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
- TypeScript binding: Node >= 22.6 (uses built-in type stripping and `node:test`; no dependencies).
- Zig binding: Zig 0.15.x.

## Layout

```
circuits/              shared example .circ files (and.circ, full_adder.circ)
ts/                    TypeScript binding + node:test examples
zig/                   Zig binding + std.testing examples
docs/writing-a-binding.md   how to implement a binding in a new language
```

## TypeScript

```ts
import { load } from "circ-test";

const dut = await load("circuits/and.circ");
await dut.set("a", 1);
await dut.set("b", 1);
await dut.settle();
console.log(await dut.getInt("out")); // 1n
await dut.close();
```

Run the examples (no install needed):

```sh
cd ts
node --test test/*.test.ts          # add CIRC_COMPILE_BIN=... if not on PATH
```

`vitest` is a drop-in alternative if you prefer it; the binding has no test-runner dependency.

## Zig

```zig
const circ = @import("circ_test");

var dut = try circ.Dut.load(allocator, "circuits/and.circ");
defer dut.close();
try dut.set("a", 1);
try dut.set("b", 1);
try dut.settle();
try std.testing.expectEqual(@as(u64, 1), try dut.getInt("out"));
```

Run the examples:

```sh
cd zig
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
