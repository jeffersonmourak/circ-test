import { test, expect } from "bun:test";
import { load } from "../src/index.ts";

const AND = new URL("../../circuits/and.circ", import.meta.url).pathname;
const FULL_ADDER = new URL("../../circuits/full_adder.circ", import.meta.url).pathname;

test("and gate: exhaustive a & b", async () => {
  const dut = await load(AND);
  try {
    for (let a = 0; a <= 1; a++) {
      for (let b = 0; b <= 1; b++) {
        await dut.set("a", a);
        await dut.set("b", b);
        await dut.settle();
        expect(await dut.getInt("out")).toBe(BigInt(a & b));
      }
    }
  } finally {
    await dut.close();
  }
});

test("full adder: sum and carry via eval, computed reference", async () => {
  const dut = await load(FULL_ADDER);
  try {
    for (let a = 0; a <= 1; a++) {
      for (let b = 0; b <= 1; b++) {
        for (let cin = 0; cin <= 1; cin++) {
          const r = await dut.eval({ a, b, cin }, ["sum", "cout"]);
          const total = a + b + cin;
          expect(r.sum.value).toBe(BigInt(total & 1));
          expect(r.cout.value).toBe(BigInt(total >> 1));
        }
      }
    }
  } finally {
    await dut.close();
  }
});

test("undefined input propagates to undefined output", async () => {
  const dut = await load(AND);
  try {
    await dut.setUndefined("a");
    await dut.set("b", 1);
    await dut.settle();
    expect(await dut.isUndefined("out")).toBe(true);
  } finally {
    await dut.close();
  }
});
