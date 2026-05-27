import { spawn } from "node:child_process";
import type { ChildProcessWithoutNullStreams } from "node:child_process";

/** Where to find the compiler: `CIRC_COMPILE_BIN`, else `circ-compile` on PATH. */
const BINARY = process.env.CIRC_COMPILE_BIN ?? "circ-compile";

/** Wire-protocol version this binding speaks (see DOCS/sim-protocol.md). */
export const PROTO_VERSION = 1;

export interface PinInfo {
  dir: "in" | "out";
  width: number;
}

/** A pin reading: `value` with a per-bit `defined` mask (0 bits are undefined). */
export interface Reading {
  value: bigint;
  defined: bigint;
  width: number;
}

export class CircError extends Error {}

/** Buffers a byte stream into newline-delimited lines, awaitable one at a time. */
class LineReader {
  #buf = "";
  #queue: string[] = [];
  #waiters: Array<(line: string | null) => void> = [];
  #ended = false;

  feed(chunk: string): void {
    this.#buf += chunk;
    let nl = this.#buf.indexOf("\n");
    while (nl >= 0) {
      const line = this.#buf.slice(0, nl);
      this.#buf = this.#buf.slice(nl + 1);
      const w = this.#waiters.shift();
      if (w) w(line);
      else this.#queue.push(line);
      nl = this.#buf.indexOf("\n");
    }
  }

  end(): void {
    this.#ended = true;
    while (this.#waiters.length) this.#waiters.shift()!(null);
  }

  next(): Promise<string | null> {
    const q = this.#queue.shift();
    if (q !== undefined) return Promise.resolve(q);
    if (this.#ended) return Promise.resolve(null);
    return new Promise((resolve) => this.#waiters.push(resolve));
  }
}

/** A circuit under test: one `circ-compile --sim` subprocess, driven by pin name. */
export class Dut {
  readonly pins = new Map<string, PinInfo>();
  #child: ChildProcessWithoutNullStreams;
  #reader: LineReader;

  constructor(child: ChildProcessWithoutNullStreams, reader: LineReader) {
    this.#child = child;
    this.#reader = reader;
  }

  /** Compile `circuitPath` and open a drive session. Throws on compile errors. */
  static async load(circuitPath: string): Promise<Dut> {
    const child = spawn(BINARY, [circuitPath, "--sim"], { stdio: ["pipe", "pipe", "pipe"] });
    const reader = new LineReader();
    let stderr = "";
    let spawnError: Error | null = null;
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (d: string) => reader.feed(d));
    child.stderr.on("data", (d: string) => (stderr += d));
    child.on("error", (e) => {
      spawnError = e;
      reader.end();
    });
    child.on("close", () => reader.end());

    const dut = new Dut(child, reader);
    const header = await reader.next();
    if (spawnError) throw new CircError(`failed to spawn ${BINARY}: ${(spawnError as Error).message}`);
    if (header === null) throw new CircError(`circ-compile produced no output${stderr ? `:\n${stderr}` : ""}`);

    if (header.startsWith("error ")) {
      const count = Number(header.slice("error diags=".length)) || 0;
      const diags: string[] = [];
      for (let i = 0; i < count; i++) {
        const line = await reader.next();
        if (line) diags.push(line);
      }
      throw new CircError(`circuit failed to compile:\n${diags.join("\n")}`);
    }

    const m = header.match(/^ready proto=(\d+) pins=(\d+) warnings=(\d+)$/);
    if (!m) throw new CircError(`unexpected handshake: ${header}`);
    if (Number(m[1]) !== PROTO_VERSION) {
      throw new CircError(`unsupported sim protocol version ${m[1]} (this binding speaks ${PROTO_VERSION})`);
    }
    const pinCount = Number(m[2]);
    const warnCount = Number(m[3]);
    for (let i = 0; i < pinCount; i++) {
      const line = await reader.next();
      const pm = line?.match(/^pin (\S+) (in|out) (\d+)$/);
      if (!pm) throw new CircError(`malformed pin record: ${line}`);
      dut.pins.set(pm[1], { dir: pm[2] as "in" | "out", width: Number(pm[3]) });
    }
    for (let i = 0; i < warnCount; i++) await reader.next();
    return dut;
  }

  async #cmd(line: string): Promise<string> {
    this.#child.stdin.write(line + "\n");
    const reply = await this.#reader.next();
    if (reply === null) throw new CircError(`circ-compile closed the stream (after: ${line})`);
    return reply;
  }

  #fullMask(width: number): bigint {
    return width >= 64 ? (1n << 64n) - 1n : (1n << BigInt(width)) - 1n;
  }

  #parseReading(name: string, valueHex: string, definedHex: string): Reading {
    return {
      value: BigInt(valueHex),
      defined: BigInt(definedHex),
      width: this.pins.get(name)?.width ?? 0,
    };
  }

  /** Drive a top-level input. Omit `mask` for fully defined; mask bit 0 = undefined. */
  async set(name: string, value: bigint | number, mask?: bigint | number): Promise<void> {
    const line = mask === undefined ? `set ${name} ${value}` : `set ${name} ${value} ${mask}`;
    const reply = await this.#cmd(line);
    if (!reply.startsWith("ok")) throw new CircError(`set ${name}: ${reply}`);
  }

  /** Drive `name` fully undefined (all bits X). */
  async setUndefined(name: string): Promise<void> {
    await this.set(name, 0, 0);
  }

  /** Settle the circuit (drains the event queue). */
  async settle(): Promise<void> {
    const reply = await this.#cmd("run");
    if (!reply.startsWith("ok")) throw new CircError(`run: ${reply}`);
  }

  /** Reset to the post-init state (all pins undefined). */
  async reset(): Promise<void> {
    const reply = await this.#cmd("reset");
    if (!reply.startsWith("ok")) throw new CircError(`reset: ${reply}`);
  }

  /** Read a pin's current `(value, defined)`. */
  async get(name: string): Promise<Reading> {
    const reply = await this.#cmd(`get ${name}`);
    const m = reply.match(/^ok (\S+) (\S+)$/);
    if (!m) throw new CircError(`get ${name}: ${reply}`);
    return this.#parseReading(name, m[1], m[2]);
  }

  /** Read a pin as an integer, throwing if any bit is undefined. */
  async getInt(name: string): Promise<bigint> {
    const r = await this.get(name);
    if (r.defined !== this.#fullMask(r.width)) {
      throw new CircError(`get ${name}: has undefined bits (defined=0x${r.defined.toString(16)})`);
    }
    return r.value;
  }

  /** True if the pin is fully undefined. */
  async isUndefined(name: string): Promise<boolean> {
    return (await this.get(name)).defined === 0n;
  }

  /** One-shot vector: apply assignments, settle, read the queried pins. */
  async eval(assigns: Record<string, bigint | number>, queries: string[]): Promise<Record<string, Reading>> {
    const lhs = Object.entries(assigns)
      .map(([k, v]) => `${k}=${v}`)
      .join(" ");
    const reply = await this.#cmd(`eval ${lhs} => ${queries.join(" ")}`);
    if (!reply.startsWith("ok")) throw new CircError(`eval: ${reply}`);
    const out: Record<string, Reading> = {};
    for (const tok of reply.slice(2).trim().split(/\s+/).filter(Boolean)) {
      const m = tok.match(/^(\S+)=([^/]+)\/(.+)$/);
      if (!m) throw new CircError(`eval: bad reply token "${tok}"`);
      out[m[1]] = this.#parseReading(m[1], m[2], m[3]);
    }
    return out;
  }

  /** End the session and the subprocess. */
  async close(): Promise<void> {
    if (this.#child.exitCode === null && !this.#child.killed) {
      this.#child.stdin.write("quit\n");
      await this.#reader.next().catch(() => null);
      this.#child.stdin.end();
    }
  }
}

/** Compile `circuitPath` and open a drive session. */
export function load(circuitPath: string): Promise<Dut> {
  return Dut.load(circuitPath);
}
