# Writing a binding in a new language

A binding is a thin client of the `circ-compile --sim` protocol. If your
language can spawn a subprocess and read/write newline-delimited text, you can
write one in a few hundred lines. The two reference bindings are
[`ts/src/index.ts`](../ts/src/index.ts) and
[`zig/src/circ_test.zig`](../zig/src/circ_test.zig); read one alongside this.

The protocol itself (`proto=1`) is specified in the compiler repo at
`DOCS/sim-protocol.md`. This guide is the implementer's checklist.

## The shape of a binding

A binding exposes a small object (call it `Dut`) backed by one subprocess:

1. **Locate the compiler.** Read `CIRC_COMPILE_BIN`; fall back to
   `circ-compile` on `PATH`.
2. **Spawn** `circ-compile <circuit-path> --sim` with piped stdin and stdout.
3. **Read the handshake** (the first reply):
   - `ready proto=<v> pins=<N> warnings=<W>` then `N` lines `pin <name> <in|out> <width>`
     then `W` `diag` lines. Reject `v != 1`.
   - `error diags=<N>` then `N` `diag` lines: the circuit did not compile;
     surface the diagnostics as a load failure.
4. **Drive** by writing one command line and reading exactly one reply (the
   protocol is synchronous: one reply per command). Map your API onto:
   - `set <pin> <value> [<mask>]` -> `set(name, value, mask?)`
   - `run` -> `settle()`
   - `get <pin>` -> `get(name)` returning `(value, defined)`
   - `eval <a=v ...> => <q ...>` -> a one-round-trip vector
   - `reset` -> `reset()`
   - `quit` (or closing stdin) -> `close()`
5. **Parse values.** Replies emit `0x`-prefixed hex; widths can be up to 64
   bits, so use a 64-bit (or big) integer type. A reading is a `(value,
   defined)` pair: bits where `defined` is 0 are undefined.

## Value and error rules to honor

- Inputs you send may be decimal or `0x`/`0o`/`0b`; the compiler accepts all.
- A `set` whose value or mask has bits beyond the pin width gets `err E_WIDTH`;
  surface it rather than masking silently.
- Replies starting with `err <CODE> <message>` should become errors in your
  language. Codes: `E_PROTO`, `E_NOPIN`, `E_NOTIN`, `E_WIDTH`, `E_BADVAL`.
- A convenience `getInt(name)` that errors when any bit is undefined, and an
  `isUndefined(name)`, cover the two common read intents.

## Minimal pseudo-code

```
fn load(path):
    proc = spawn(compiler_bin(), [path, "--sim"])
    header = proc.readline()
    if header starts with "error": collect diags, raise CompileError
    parse "ready proto=1 pins=N warnings=W"; assert proto == 1
    read N pin records into a name -> {dir, width} map
    skip W diag lines
    return Dut(proc, pins)

fn Dut.cmd(line):
    proc.write(line + "\n")
    return proc.readline()

fn Dut.set(name, value, mask=None):
    reply = cmd(mask is None ? "set {name} {value}" : "set {name} {value} {mask}")
    if not reply.startswith("ok"): raise Error(reply)

fn Dut.get(name):
    reply = cmd("get {name}")          # "ok <valueHex> <definedHex>"
    _, v, d = reply.split()
    return (parse_int(v), parse_int(d))
```

## Checklist

- [ ] Resolves the compiler via `CIRC_COMPILE_BIN` then `PATH`.
- [ ] Rejects a `proto` mismatch in the handshake.
- [ ] Turns an `error` handshake into a load failure carrying the diagnostics.
- [ ] One write + one read per command (synchronous).
- [ ] 64-bit-safe value parsing; preserves the `(value, defined)` pair.
- [ ] Maps `err <CODE>` replies onto language-level errors.
- [ ] `close()` sends `quit` (or closes stdin) and reaps the subprocess.
