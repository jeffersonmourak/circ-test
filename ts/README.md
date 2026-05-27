# circ-test

Behavioral test harness for [circ-compiler](https://github.com/jeffersonmourak/circ-compiler) circuits. Write expectations against a `.circ` circuit in your own test runner — they run against the real compiled simulation engine.

```
  your test (bun:test / vitest / node:test / ...)
        |   load / set / settle / get / eval
        v
  circ-test  ──spawn──▶  circ-compile <circuit>.circ --sim
        ▲                       │  (native simulation engine)
        └────── replies ◀────────┘
```

## Install

```sh
npm install circ-test
# or
bun add circ-test
```

## Prerequisites

`circ-compile` must be on your `PATH`, or point `CIRC_COMPILE_BIN` at the binary:

```sh
CIRC_COMPILE_BIN=./path/to/circ-compile bun test
```

## Quick start

```ts
import { load } from "circ-test";

const dut = await load("circuits/and.circ");

await dut.set("a", 1);
await dut.set("b", 1);
await dut.settle();

console.log(await dut.getInt("out")); // 1n

await dut.close();
```

Works with any test runner. Example with `bun:test`:

```ts
import { test, expect } from "bun:test";
import { load } from "circ-test";

test("and gate", async () => {
  const dut = await load("circuits/and.circ");
  try {
    await dut.set("a", 1);
    await dut.set("b", 0);
    await dut.settle();
    expect(await dut.getInt("out")).toBe(0n);
  } finally {
    await dut.close();
  }
});
```

## API

### `load(circuitPath: string): Promise<Dut>`

Compiles `circuitPath` and opens a simulation session. Throws `CircError` on compile failure or spawn error.

---

### `class Dut`

#### `dut.pins: Map<string, PinInfo>`

All pins declared by the circuit, populated after `load`. Each entry is `{ dir: "in" | "out", width: number }`.

#### `dut.set(name, value, mask?): Promise<void>`

Drive an input pin to `value`. Pass `mask` to mark specific bits as undefined (0 bit = undefined). Omit `mask` for a fully-defined drive.

#### `dut.setUndefined(name): Promise<void>`

Drive `name` fully undefined (all bits X).

#### `dut.settle(): Promise<void>`

Drain the event queue — propagate all pending signal changes.

#### `dut.reset(): Promise<void>`

Return the circuit to its post-init state (all pins undefined).

#### `dut.get(name): Promise<Reading>`

Read the current state of a pin. Returns `{ value: bigint, defined: bigint, width: number }`. Bits where `defined` is 0 are undefined (X).

#### `dut.getInt(name): Promise<bigint>`

Read a pin as an integer. Throws `CircError` if any bit is undefined.

#### `dut.isUndefined(name): Promise<boolean>`

`true` if every bit of `name` is undefined.

#### `dut.eval(assigns, queries): Promise<Record<string, Reading>>`

One-shot: apply `assigns`, settle, return readings for all `queries`. More efficient than separate `set` / `settle` / `get` calls when driving multiple inputs at once.

```ts
const r = await dut.eval({ a: 1, b: 1 }, ["out"]);
// r.out.value === 1n
```

#### `dut.close(): Promise<void>`

End the session and terminate the subprocess. Always call this when done — use `try/finally`.

---

### `class CircError extends Error`

Thrown on compile errors, protocol mismatches, or unexpected subprocess behavior.

### `PROTO_VERSION: number`

The sim wire-protocol version this binding speaks. The handshake validates this against the compiler; a mismatch throws immediately at `load` time.

## Runtime

Requires **Bun ≥ 1.0** or **Node ≥ 22**. No runtime dependencies.

## License

GPL-3.0-or-later
