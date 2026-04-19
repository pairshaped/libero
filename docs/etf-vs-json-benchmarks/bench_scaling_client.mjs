// Client-side (V8) scaling benchmark: ETF decode vs JSON.parse + rebuild
// at varying payload sizes.
//
// Usage:
//   cd <project>/server
//   node ../lib/libero/benchmarks/bench_scaling_client.mjs

import { execSync } from "child_process";

// --- ETF Decoder (from rpc_ffi.mjs, standalone) ---

class ETFDecoder {
  constructor(buffer) {
    this.view = new DataView(buffer);
    this.bytes = new Uint8Array(buffer);
    this.offset = 0;
  }
  readUint8() { const v = this.view.getUint8(this.offset); this.offset += 1; return v; }
  readUint16() { const v = this.view.getUint16(this.offset, false); this.offset += 2; return v; }
  readUint32() { const v = this.view.getUint32(this.offset, false); this.offset += 4; return v; }
  readInt32() { const v = this.view.getInt32(this.offset, false); this.offset += 4; return v; }
  readFloat64() { const v = this.view.getFloat64(this.offset, false); this.offset += 8; return v; }
  readBytes(n) { const b = new Uint8Array(this.view.buffer, this.offset, n); this.offset += n; return b; }
  readString(n) { return new TextDecoder().decode(this.readBytes(n)); }
  decode() { if (this.readUint8() !== 131) throw new Error("bad version"); return this.decodeTerm(); }
  decodeTerm() {
    const tag = this.readUint8();
    switch (tag) {
      case 70: return this.readFloat64();
      case 97: return this.readUint8();
      case 98: return this.readInt32();
      case 104: return this.decodeTuple(this.readUint8());
      case 105: return this.decodeTuple(this.readUint32());
      case 106: return null; // empty list (linked list nil)
      case 107: { const len = this.readUint16(); const a = []; for (let i = 0; i < len; i++) a.push(this.readUint8()); return a; }
      case 108: return this.decodeList(); // builds linked list
      case 109: return this.readString(this.readUint32());
      case 110: return this.decodeBigInt(this.readUint8());
      case 111: return this.decodeBigInt(this.readUint32());
      case 116: return this.decodeMap();
      case 118: return this.decodeAtom(this.readUint16());
      case 119: return this.decodeAtom(this.readUint8());
      default: throw new Error(`unknown tag ${tag}`);
    }
  }
  decodeAtom(len) {
    const name = this.readString(len);
    if (name === "true") return true;
    if (name === "false") return false;
    if (name === "nil" || name === "undefined") return undefined;
    return { __atom: name };
  }
  decodeTuple(arity) {
    if (arity === 0) return [];
    const ft = this.bytes[this.offset];
    if (ft === 118 || ft === 119) {
      this.offset += 1;
      const al = ft === 119 ? this.readUint8() : this.readUint16();
      const an = this.readString(al);
      if (an === "true" || an === "false" || an === "nil" || an === "undefined") {
        const v = an === "true" ? true : an === "false" ? false : undefined;
        const e = [v]; for (let i = 1; i < arity; i++) e.push(this.decodeTerm()); return e;
      }
      const f = []; for (let i = 1; i < arity; i++) f.push(this.decodeTerm());
      return { __tag: an, fields: f };
    }
    const e = []; for (let i = 0; i < arity; i++) e.push(this.decodeTerm());
    return e;
  }
  decodeList() { const c = this.readUint32(); const e = []; for (let i = 0; i < c; i++) e.push(this.decodeTerm()); this.decodeTerm(); let list = null; for (let i = e.length - 1; i >= 0; i--) list = { head: e[i], tail: list }; return list; }
  decodeMap() { const a = this.readUint32(); const m = new Map(); for (let i = 0; i < a; i++) { m.set(this.decodeTerm(), this.decodeTerm()); } return m; }
  decodeBigInt(n) { const s = this.readUint8(); const d = this.readBytes(n); let v = 0; for (let i = d.length - 1; i >= 0; i--) v = v * 256 + d[i]; return s === 1 ? -v : v; }
}

class FakeConstructor {
  constructor(...fields) {
    for (let i = 0; i < fields.length; i++) this[`f${i}`] = fields[i];
  }
}

function arrayToLinkedList(arr) {
  let list = null;
  for (let i = arr.length - 1; i >= 0; i--) {
    list = { head: arr[i], tail: list };
  }
  return list;
}

function jsonRebuild(value) {
  if (value === null) return undefined;
  if (typeof value !== "object") return value;
  if (Array.isArray(value)) {
    return arrayToLinkedList(value.map(jsonRebuild));
  }
  if ("@" in value) {
    const tag = value["@"];
    if (tag === "dict") {
      const pairs = (value.v || []).map(pair => [jsonRebuild(pair[0]), jsonRebuild(pair[1])]);
      return new Map(pairs);
    }
    const fields = (value.v || []).map(jsonRebuild);
    return new FakeConstructor(...fields);
  }
  return value;
}

// --- Generate test data ---

console.log("Generating test data from Erlang...\n");
const output = execSync(
  `erl -pa build/dev/erlang/*/ebin -noshell -eval 'bench_scaling:run_generate().'`,
  { encoding: "utf-8", maxBuffer: 10 * 1024 * 1024 }
).trim();

const lines = output.split("\n");
const payloads = [];
for (let i = 0; i < lines.length; i += 3) {
  const label = lines[i];
  const etfBuf = Uint8Array.from(atob(lines[i + 1]), c => c.charCodeAt(0)).buffer;
  const jsonStr = atob(lines[i + 2]);
  payloads.push({ label, etfBuf, jsonStr });
}

// --- Benchmark ---

console.log(`=== Client-side V8/Node ${process.version}: ETF vs JSON scaling ===\n`);
console.log("Payload                  ETF dec     JSON.parse  JSON+rebuild  ETF vs parse  ETF vs rebuild  ETF size    JSON size");
console.log("-".repeat(120));

for (const { label, etfBuf, jsonStr } of payloads) {
  const etfSize = etfBuf.byteLength;
  const jsonSize = new TextEncoder().encode(jsonStr).byteLength;

  // Scale iterations: fewer for bigger payloads
  const N = etfSize < 5000 ? 100_000 : etfSize < 50_000 ? 10_000 : 1_000;
  const warmup = Math.max(100, Math.floor(N / 10));

  // Warmup
  for (let i = 0; i < warmup; i++) {
    new ETFDecoder(etfBuf).decode();
    jsonRebuild(JSON.parse(jsonStr));
  }

  // ETF decode
  const etfStart = performance.now();
  for (let i = 0; i < N; i++) new ETFDecoder(etfBuf).decode();
  const etfUs = (performance.now() - etfStart) / N * 1000;

  // JSON.parse only
  const jpStart = performance.now();
  for (let i = 0; i < N; i++) JSON.parse(jsonStr);
  const jpUs = (performance.now() - jpStart) / N * 1000;

  // JSON.parse + rebuild
  const jrStart = performance.now();
  for (let i = 0; i < N; i++) jsonRebuild(JSON.parse(jsonStr));
  const jrUs = (performance.now() - jrStart) / N * 1000;

  const pad = (s, w) => s.padStart(w);
  const fmtBytes = (b) => b < 1024 ? `${b} B` : b < 1048576 ? `${(b/1024).toFixed(1)} KB` : `${(b/1048576).toFixed(1)} MB`;

  console.log(
    `${label.padEnd(24)} ` +
    `${pad(etfUs.toFixed(1), 8)} us ` +
    `${pad(jpUs.toFixed(1), 8)} us  ` +
    `${pad(jrUs.toFixed(1), 8)} us  ` +
    `${pad((etfUs / jpUs).toFixed(1), 8)}x     ` +
    `${pad((etfUs / jrUs).toFixed(1), 8)}x     ` +
    `${fmtBytes(etfSize).padStart(9)}  ${fmtBytes(jsonSize).padStart(9)}`
  );
}
