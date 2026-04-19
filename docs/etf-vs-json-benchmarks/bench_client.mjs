// Client-side (V8) benchmark: ETF decode vs JSON.parse + rebuild.
//
// Usage:
//   cd <project>/server
//   node ../lib/libero/benchmarks/bench_client.mjs
//
// Generates test data by shelling out to erl, then benchmarks
// ETF decoding vs JSON parsing (with and without rebuild).

import { execSync } from "child_process";

// --- Generate test data from Erlang ---

const erlCode = `
  J = 'gleam@json',
  D = {discount, 1, 1, <<"Early Bird">>, {some, <<"Inscription native">>},
       10.0, 0, true, false, false, false, [], none, none, none,
       none, none, false, none, none, none, 1712000000, 1712000000},
  Discounts = [D, D, D, D, D],
  Response = {ok, {admin_data, Discounts, Discounts,
    [{item_option, 1, <<"League A">>}, {item_option, 2, <<"League B">>},
     {item_option, 3, <<"Tournament C">>}, {item_option, 4, <<"Camp D">>}],
    [{question_option, <<"gender">>, <<"Gender">>, <<"select">>},
     {question_option, <<"age">>, <<"Age">>, <<"number">>}],
    #{<<"gender">> => [{<<"male">>, <<"Male">>}, {<<"female">>, <<"Female">>},
                       {<<"unspecified">>, <<"Unspecified">>}]}
  }},
  ETF = erlang:term_to_binary(Response),
  Walk = fun Walk(Term) ->
    if
      is_boolean(Term) -> J:bool(Term);
      Term =:= nil -> J:null();
      is_atom(Term) -> J:object([{<<"@">>, J:string(atom_to_binary(Term))}, {<<"v">>, J:preprocessed_array([])}]);
      is_integer(Term) -> J:int(Term);
      is_float(Term) -> J:float(Term);
      is_binary(Term) -> J:string(Term);
      is_list(Term) -> J:preprocessed_array([Walk(E) || E <- Term]);
      is_map(Term) ->
        Pairs = [J:preprocessed_array([Walk(K), Walk(V)]) || {K, V} <- maps:to_list(Term)],
        J:object([{<<"@">>, J:string(<<"dict">>)}, {<<"v">>, J:preprocessed_array(Pairs)}]);
      is_tuple(Term) ->
        [First | Rest] = tuple_to_list(Term),
        case is_atom(First) andalso not is_boolean(First) of
          true -> J:object([{<<"@">>, J:string(atom_to_binary(First))}, {<<"v">>, J:preprocessed_array([Walk(E) || E <- Rest])}]);
          false -> J:preprocessed_array([Walk(E) || E <- tuple_to_list(Term)])
        end
    end
  end,
  JsonBin = iolist_to_binary(J:to_string(Walk(Response))),
  io:format("~s\\n~s", [base64:encode(ETF), base64:encode(JsonBin)]),
  halt()
`;

console.log("Generating test data from Erlang...");
const output = execSync(
  `erl -pa build/dev/erlang/*/ebin -noshell -eval '${erlCode.replace(/'/g, "'\\''")}'`,
  { encoding: "utf-8", maxBuffer: 1024 * 1024 }
).trim();

const [etfB64, jsonB64] = output.split("\n");
const etfBuf = Uint8Array.from(atob(etfB64), c => c.charCodeAt(0)).buffer;
const jsonStr = atob(jsonB64);

console.log(`ETF: ${etfBuf.byteLength} bytes, JSON: ${new TextEncoder().encode(jsonStr).byteLength} bytes\n`);

// --- Inline ETF decoder (from rpc_ffi.mjs, standalone mode) ---

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

  decode() {
    if (this.readUint8() !== 131) throw new Error("bad version");
    return this.decodeTerm();
  }

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

  decodeList() {
    const c = this.readUint32(); const e = [];
    for (let i = 0; i < c; i++) e.push(this.decodeTerm());
    this.decodeTerm(); // tail
    let list = null;
    for (let i = e.length - 1; i >= 0; i--) list = { head: e[i], tail: list };
    return list;
  }

  decodeMap() {
    const a = this.readUint32(); const m = new Map();
    for (let i = 0; i < a; i++) { m.set(this.decodeTerm(), this.decodeTerm()); } return m;
  }

  decodeBigInt(n) {
    const s = this.readUint8(); const d = this.readBytes(n);
    let v = 0; for (let i = d.length - 1; i >= 0; i--) v = v * 256 + d[i];
    return s === 1 ? -v : v;
  }
}

// --- JSON rebuild (simulates rpc_ffi.mjs rebuild with constructor
//     instantiation, linked list construction, and Dict reconstruction) ---

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
  if (value === null) return undefined; // null -> Nil
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

// --- Benchmark ---

const N = 100_000;
const WARMUP = 10_000;

// Warmup
for (let i = 0; i < WARMUP; i++) {
  new ETFDecoder(etfBuf).decode();
  jsonRebuild(JSON.parse(jsonStr));
}

// ETF decode
const etfStart = performance.now();
for (let i = 0; i < N; i++) new ETFDecoder(etfBuf).decode();
const etfMs = performance.now() - etfStart;

// JSON.parse only
const jpStart = performance.now();
for (let i = 0; i < N; i++) JSON.parse(jsonStr);
const jpMs = performance.now() - jpStart;

// JSON.parse + rebuild
const jrStart = performance.now();
for (let i = 0; i < N; i++) jsonRebuild(JSON.parse(jsonStr));
const jrMs = performance.now() - jrStart;

console.log(`=== Client-side V8/Node ${process.version} (${N.toLocaleString()} iterations) ===\n`);
console.log(`                    Total       Per-op`);
console.log(`ETF decode          ${etfMs.toFixed(0).padStart(6)} ms    ${(etfMs / N * 1000).toFixed(1).padStart(6)} us/op`);
console.log(`JSON.parse          ${jpMs.toFixed(0).padStart(6)} ms    ${(jpMs / N * 1000).toFixed(1).padStart(6)} us/op`);
console.log(`JSON parse+rebuild  ${jrMs.toFixed(0).padStart(6)} ms    ${(jrMs / N * 1000).toFixed(1).padStart(6)} us/op`);
console.log();
console.log(`ETF vs JSON.parse:          ${(etfMs / jpMs).toFixed(1)}x slower`);
console.log(`ETF vs JSON parse+rebuild:  ${(etfMs / jrMs).toFixed(1)}x slower`);
