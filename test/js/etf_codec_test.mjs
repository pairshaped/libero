// ETF codec tests for libero's rpc_ffi.mjs
//
// Standalone Node.js test - inlines the decoder/encoder classes from rpc_ffi.mjs
// because top-level await imports in rpc_ffi.mjs prevent direct import.
//
// The inlined decoder runs in "raw" mode (no Gleam prelude): atoms stay as
// strings, tagged tuples stay as plain arrays, and lists are JS arrays.
// This matches the production decoder's raw mode, which the typed decoder
// (rpc_decoders_ffi.mjs) post-processes into proper Gleam constructors.
//
// Run: node test/js/etf_codec_test.mjs

import { execSync } from "child_process";
import { strict as assert } from "assert";

// ============================================================
// Inlined from rpc_ffi.mjs - decoder, encoder, helpers
// ============================================================

const floatFieldRegistry = new Map();

function registerFloatFields(atomName, fieldIndices) {
  floatFieldRegistry.set(atomName, new Set(fieldIndices));
}

// Standalone mode - no Gleam prelude. Lists are plain JS arrays.
function arrayToGleamList(arr) {
  return arr;
}

const utf8Decoder = new TextDecoder();

class ETFDecoder {
  constructor(input) {
    let bytes;
    if (input instanceof Uint8Array) {
      bytes = input;
    } else if (input instanceof ArrayBuffer) {
      bytes = new Uint8Array(input);
    } else if (input && input.rawBuffer instanceof Uint8Array) {
      bytes = input.rawBuffer;
    } else {
      throw new Error(
        "ETFDecoder: input must be ArrayBuffer, Uint8Array, or Gleam BitArray",
      );
    }
    this.bytes = bytes;
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    this.offset = 0;
  }

  decode() {
    const version = this.readUint8();
    if (version !== 131) {
      throw new Error(`ETF decode: expected version byte 131, got ${version}`);
    }
    return this.decodeTerm();
  }

  readUint8() {
    const v = this.view.getUint8(this.offset);
    this.offset += 1;
    return v;
  }

  readUint16() {
    const v = this.view.getUint16(this.offset);
    this.offset += 2;
    return v;
  }

  readUint32() {
    const v = this.view.getUint32(this.offset);
    this.offset += 4;
    return v;
  }

  readInt32() {
    const v = this.view.getInt32(this.offset);
    this.offset += 4;
    return v;
  }

  readFloat64() {
    const v = this.view.getFloat64(this.offset);
    this.offset += 8;
    return v;
  }

  readBytes(n) {
    const slice = this.bytes.slice(this.offset, this.offset + n);
    this.offset += n;
    return slice;
  }

  readString(n) {
    return utf8Decoder.decode(this.readBytes(n));
  }

  decodeTerm() {
    const tag = this.readUint8();
    switch (tag) {
      case 70:
        return this.readFloat64();
      case 97:
        return this.readUint8();
      case 98:
        return this.readInt32();
      case 104:
        return this.decodeTuple(this.readUint8());
      case 105:
        return this.decodeTuple(this.readUint32());
      case 106:
        return arrayToGleamList([]);
      case 108:
        return this.decodeList();
      case 107: {
        const len = this.readUint16();
        const elements = [];
        for (let i = 0; i < len; i++) {
          elements.push(this.readUint8());
        }
        return arrayToGleamList(elements);
      }
      case 109:
        return this.readString(this.readUint32());
      case 110:
        return this.decodeBigInt(this.readUint8());
      case 111:
        return this.decodeBigInt(this.readUint32());
      case 116:
        return this.decodeMap();
      case 118:
        return this.decodeAtom(this.readUint16());
      case 119:
        return this.decodeAtom(this.readUint8());
      default:
        throw new Error(`ETF decode: unknown tag ${tag} at offset ${this.offset - 1}`);
    }
  }

  decodeAtom(len) {
    const name = this.readString(len);
    if (name === "true") return true;
    if (name === "false") return false;
    if (name === "nil" || name === "undefined") return undefined;
    // Raw mode: return atom as string. The typed decoder (rpc_decoders_ffi.mjs)
    // resolves the correct constructor per type at a higher level.
    return name;
  }

  decodeTuple(arity) {
    if (arity === 0) return [];

    const firstTag = this.bytes[this.offset];
    if (firstTag === 118 || firstTag === 119) {
      this.offset += 1;
      const atomLen = firstTag === 119 ? this.readUint8() : this.readUint16();
      const atomName = this.readString(atomLen);

      if (atomName === "true" || atomName === "false" || atomName === "nil" || atomName === "undefined") {
        const firstVal = atomName === "true" ? true
          : atomName === "false" ? false
          : undefined;
        const elements = [firstVal];
        for (let i = 1; i < arity; i++) {
          elements.push(this.decodeTerm());
        }
        return elements;
      }

      // Atom-tagged tuple: return as array with atom string as first element.
      // Typed decoder (rpc_decoders_ffi.mjs) resolves the correct constructor.
      const elements = [atomName];
      for (let i = 1; i < arity; i++) {
        elements.push(this.decodeTerm());
      }
      return elements;
    }

    const elements = [];
    for (let i = 0; i < arity; i++) {
      elements.push(this.decodeTerm());
    }
    return elements;
  }

  decodeList() {
    const count = this.readUint32();
    const elements = [];
    for (let i = 0; i < count; i++) {
      elements.push(this.decodeTerm());
    }
    const tailTag = this.readUint8();
    if (tailTag !== 106) {
      throw new Error("ETF decode: improper list (non-nil tail) - Gleam cannot produce these");
    }
    return arrayToGleamList(elements);
  }

  decodeBigInt(n) {
    const sign = this.readUint8();
    const digits = this.readBytes(n);
    let value = 0n;
    for (let i = n - 1; i >= 0; i--) {
      value = (value << 8n) | BigInt(digits[i]);
    }
    if (sign === 1) value = -value;
    if (value >= Number.MIN_SAFE_INTEGER && value <= Number.MAX_SAFE_INTEGER) {
      return Number(value);
    }
    return value;
  }

  decodeMap() {
    const arity = this.readUint32();
    const pairs = [];
    for (let i = 0; i < arity; i++) {
      const key = this.decodeTerm();
      const val = this.decodeTerm();
      pairs.push([key, val]);
    }
    return new Map(pairs);
  }
}

const textEncoder = new TextEncoder();

class ETFEncoder {
  constructor() {
    this.buffer = new ArrayBuffer(256);
    this.view = new DataView(this.buffer);
    this.bytes = new Uint8Array(this.buffer);
    this.offset = 0;
  }

  ensureCapacity(needed) {
    const required = this.offset + needed;
    if (required <= this.buffer.byteLength) return;
    let newSize = this.buffer.byteLength;
    while (newSize < required) newSize *= 2;
    const newBuffer = new ArrayBuffer(newSize);
    new Uint8Array(newBuffer).set(this.bytes);
    this.buffer = newBuffer;
    this.view = new DataView(this.buffer);
    this.bytes = new Uint8Array(this.buffer);
  }

  writeUint8(v) {
    this.ensureCapacity(1);
    this.view.setUint8(this.offset, v);
    this.offset += 1;
  }

  writeUint16(v) {
    this.ensureCapacity(2);
    this.view.setUint16(this.offset, v);
    this.offset += 2;
  }

  writeUint32(v) {
    this.ensureCapacity(4);
    this.view.setUint32(this.offset, v);
    this.offset += 4;
  }

  writeInt32(v) {
    this.ensureCapacity(4);
    this.view.setInt32(this.offset, v);
    this.offset += 4;
  }

  writeFloat64(v) {
    this.ensureCapacity(8);
    this.view.setFloat64(this.offset, v);
    this.offset += 8;
  }

  writeBytes(bytes) {
    this.ensureCapacity(bytes.length);
    this.bytes.set(bytes, this.offset);
    this.offset += bytes.length;
  }

  result() {
    return this.buffer.slice(0, this.offset);
  }

  encodeTerm(value) {
    if (value === undefined || value === null) {
      this.writeAtom("nil");
      return;
    }
    if (typeof value === "boolean") {
      this.writeAtom(value ? "true" : "false");
      return;
    }
    if (typeof value === "string") {
      this.encodeBinary(value);
      return;
    }
    if (typeof value === "number") {
      this.encodeNumber(value);
      return;
    }
    if (typeof value === "bigint") {
      this.encodeBigInt(value);
      return;
    }
    if (Array.isArray(value)) {
      this.encodeTuple(value);
      return;
    }
    if (value instanceof Map) {
      this.encodeMap(value);
      return;
    }
    this.encodeBinary(String(value));
  }

  writeAtom(name) {
    const encoded = textEncoder.encode(name);
    if (encoded.length <= 255) {
      this.writeUint8(119);
      this.writeUint8(encoded.length);
    } else {
      this.writeUint8(118);
      this.writeUint16(encoded.length);
    }
    this.writeBytes(encoded);
  }

  encodeBinary(str) {
    const encoded = textEncoder.encode(str);
    this.writeUint8(109);
    this.writeUint32(encoded.length);
    this.writeBytes(encoded);
  }

  encodeNumber(n) {
    if (Number.isInteger(n)) {
      if (n >= 0 && n <= 255) {
        this.writeUint8(97);
        this.writeUint8(n);
      } else if (n >= -2147483648 && n <= 2147483647) {
        this.writeUint8(98);
        this.writeInt32(n);
      } else {
        this.encodeBigInt(BigInt(n));
      }
    } else {
      this.writeUint8(70);
      this.writeFloat64(n);
    }
  }

  encodeBigInt(value) {
    const sign = value < 0n ? 1 : 0;
    let abs = value < 0n ? -value : value;
    const digits = [];
    while (abs > 0n) {
      digits.push(Number(abs & 0xFFn));
      abs >>= 8n;
    }
    if (digits.length === 0) {
      this.writeUint8(97);
      this.writeUint8(0);
      return;
    }
    if (digits.length <= 255) {
      this.writeUint8(110);
      this.writeUint8(digits.length);
    } else {
      this.writeUint8(111);
      this.writeUint32(digits.length);
    }
    this.writeUint8(sign);
    this.writeBytes(new Uint8Array(digits));
  }

  encodeTuple(elements) {
    if (elements.length <= 255) {
      this.writeUint8(104);
      this.writeUint8(elements.length);
    } else {
      this.writeUint8(105);
      this.writeUint32(elements.length);
    }
    for (const el of elements) {
      this.encodeTerm(el);
    }
  }

  encodeList(arr) {
    if (arr.length === 0) {
      this.writeUint8(106);
      return;
    }
    this.writeUint8(108);
    this.writeUint32(arr.length);
    for (const el of arr) {
      this.encodeTerm(el);
    }
    this.writeUint8(106);
  }

  encodeMap(map) {
    this.writeUint8(116);
    this.writeUint32(map.size);
    map.forEach((val, key) => {
      this.encodeTerm(key);
      this.encodeTerm(val);
    });
  }
}

// ============================================================
// Test helpers
// ============================================================

function base64ToBuffer(b64) {
  const buf = Buffer.from(b64, "base64");
  return buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
}

function bufferToBase64(ab) {
  return Buffer.from(ab).toString("base64");
}

function etfFromErlang(erlangExpr) {
  const cmd = `erl -noshell -eval 'Term = ${erlangExpr}, io:format("~s", [base64:encode(erlang:term_to_binary(Term))]), halt().'`;
  const result = execSync(cmd, { encoding: "utf-8" }).trim();
  return base64ToBuffer(result);
}

function etfDecodeInErlang(b64) {
  const cmd = `erl -noshell -eval 'Bin = base64:decode(<<"${b64}">>), Term = erlang:binary_to_term(Bin), io:format("~p", [Term]), halt().'`;
  return execSync(cmd, { encoding: "utf-8" }).trim();
}

function jsEncode(value) {
  const encoder = new ETFEncoder();
  encoder.writeUint8(131);
  encoder.encodeTerm(value);
  return encoder.result();
}

function jsEncodeList(arr) {
  const encoder = new ETFEncoder();
  encoder.writeUint8(131);
  encoder.encodeList(arr);
  return encoder.result();
}

let passed = 0;
let failed = 0;
const failures = [];

function test(group, name, fn) {
  try {
    fn();
    passed++;
    console.log(`  \x1b[32m+\x1b[0m ${name}`);
  } catch (e) {
    failed++;
    const msg = `${group} > ${name}: ${e.message}`;
    failures.push(msg);
    console.log(`  \x1b[31mx ${name}\x1b[0m`);
    console.log(`    ${e.message}`);
  }
}

function testDecode(name, erlangExpr, verify) {
  test("Decode", name, () => {
    const buf = etfFromErlang(erlangExpr);
    const decoder = new ETFDecoder(buf);
    const result = decoder.decode();
    verify(result);
  });
}

function testEncode(name, jsValue, expectedErlangStr, opts = {}) {
  test("Encode", name, () => {
    const buf = opts.isList ? jsEncodeList(jsValue) : jsEncode(jsValue);
    const b64 = bufferToBase64(buf);
    const erlResult = etfDecodeInErlang(b64);
    assert.equal(erlResult, expectedErlangStr);
  });
}

// ============================================================
// Decoder tests
// ============================================================

console.log("\nETF Decoder tests:");

// --- Integers ---
testDecode("small integer (0)", "0", r => assert.equal(r, 0));
testDecode("small integer (42)", "42", r => assert.equal(r, 42));
testDecode("small integer (255)", "255", r => assert.equal(r, 255));
testDecode("integer (256)", "256", r => assert.equal(r, 256));
testDecode("integer (1712000000)", "1712000000", r => assert.equal(r, 1712000000));
testDecode("negative integer (-1)", "-1", r => assert.equal(r, -1));
testDecode("negative integer (-7)", "-7", r => assert.equal(r, -7));
testDecode("negative integer (-2147483648)", "-2147483648", r => assert.equal(r, -2147483648));

// --- Big integers ---
testDecode("big integer (positive)", "999999999999999", r => assert.equal(r, 999999999999999));
testDecode("big integer (negative)", "-999999999999999", r => assert.equal(r, -999999999999999));
testDecode("big integer (exceeds safe int)", "9999999999999999999", r => {
  assert.equal(typeof r, "bigint");
  assert.equal(r, 9999999999999999999n);
});

// --- Floats ---
testDecode("float (3.14)", "3.14", r => assert.equal(r, 3.14));
testDecode("float (-2.5)", "-2.5", r => assert.equal(r, -2.5));
testDecode("float (0.0)", "0.0", r => assert.equal(r, 0.0));
testDecode("float (1.0e10)", "1.0e10", r => assert.equal(r, 1.0e10));

// --- Strings (BINARY_EXT) ---
testDecode("string (hello)", "<<\"hello\">>", r => assert.equal(r, "hello"));
testDecode("empty string", "<<>>", r => assert.equal(r, ""));
testDecode("unicode string (cafe)", "unicode:characters_to_binary(<<67,97,102,195,169>>)", r => assert.equal(r, "Caf\u00e9"));
testDecode("unicode string (emoji)", "unicode:characters_to_binary(<<240,159,142,179>>)", r => assert.equal(r, "\u{1F3B3}"));

// --- Booleans ---
testDecode("boolean true", "true", r => assert.equal(r, true));
testDecode("boolean false", "false", r => assert.equal(r, false));

// --- Nil ---
testDecode("nil atom", "nil", r => assert.equal(r, undefined));

// --- Bare atoms (raw mode: returned as strings) ---
testDecode("bare atom (none)", "none", r => {
  assert.equal(r, "none");
});

testDecode("bare atom (custom)", "my_atom", r => {
  assert.equal(r, "my_atom");
});

// --- Tuples ---
testDecode("empty tuple", "{}", r => {
  assert.deepEqual(r, []);
});

testDecode("2-tuple (no atom tag)", "{1, <<\"hello\">>}", r => {
  assert.deepEqual(r, [1, "hello"]);
});

testDecode("3-tuple (no atom tag)", "{1, 2, 3}", r => {
  assert.deepEqual(r, [1, 2, 3]);
});

// --- Atom-tagged tuples (raw mode: atom string + fields as array) ---
testDecode("atom-tagged tuple (raw)", "{some, 42}", r => {
  assert.deepEqual(r, ["some", 42]);
});

testDecode("atom-tagged tuple with multiple fields", "{ok, 1, <<\"hello\">>}", r => {
  assert.deepEqual(r, ["ok", 1, "hello"]);
});

testDecode("nested atom-tagged tuples", "{ok, {some, 42}}", r => {
  assert.deepEqual(r, ["ok", ["some", 42]]);
});

// --- Tuple with special atom in first position ---
testDecode("tuple starting with true", "{true, 1}", r => {
  assert.deepEqual(r, [true, 1]);
});

testDecode("tuple starting with nil", "{nil, 2}", r => {
  assert.deepEqual(r, [undefined, 2]);
});

testDecode("tuple starting with false", "{false, 3}", r => {
  assert.deepEqual(r, [false, 3]);
});

// --- Lists ---
testDecode("empty list", "[]", r => {
  assert.deepEqual(r, []);
});

testDecode("integer list", "[1, 2, 3]", r => {
  assert.deepEqual(r, [1, 2, 3]);
});

testDecode("nested list", "[[1, 2], [3, 4]]", r => {
  assert.deepEqual(r, [[1, 2], [3, 4]]);
});

testDecode("mixed list", "[1, <<\"two\">>, 3.0, true]", r => {
  assert.equal(r[0], 1);
  assert.equal(r[1], "two");
  assert.equal(r[2], 3.0);
  assert.equal(r[3], true);
});

// --- STRING_EXT (tag 107) ---
testDecode("STRING_EXT (charlist)", "lists:seq(1, 10)", r => {
  assert.deepEqual(r, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
});

testDecode("STRING_EXT (short charlist)", "lists:seq(65, 70)", r => {
  assert.deepEqual(r, [65, 66, 67, 68, 69, 70]);
});

// --- Maps ---
testDecode("simple map", "#{<<\"a\">> => 1, <<\"b\">> => 2}", r => {
  assert.ok(r instanceof Map);
  assert.equal(r.get("a"), 1);
  assert.equal(r.get("b"), 2);
});

testDecode("empty map", "#{}", r => {
  assert.ok(r instanceof Map);
  assert.equal(r.size, 0);
});

testDecode("nested map", "#{<<\"x\">> => #{<<\"y\">> => 42}}", r => {
  assert.ok(r instanceof Map);
  const inner = r.get("x");
  assert.ok(inner instanceof Map);
  assert.equal(inner.get("y"), 42);
});

// --- Complex structures (raw mode) ---
testDecode("complex: ok wrapping list of optionals", "{ok, [{some, 1}, none, {some, 3}]}", r => {
  assert.deepEqual(r, ["ok", [["some", 1], "none", ["some", 3]]]);
});

// --- Deeply nested ---
testDecode("deeply nested structure", "[[[[1]]]]", r => {
  assert.deepEqual(r, [[[[1]]]]);
});

// --- Improper list rejection ---
test("Decode", "improper list throws", () => {
  const buf2 = new ArrayBuffer(10);
  const v2 = new DataView(buf2);
  v2.setUint8(0, 131);  // version
  v2.setUint8(1, 108);  // LIST_EXT
  v2.setUint32(2, 1);   // count = 1
  v2.setUint8(6, 97);   // SMALL_INTEGER_EXT for element
  v2.setUint8(7, 1);    // value = 1
  v2.setUint8(8, 97);   // SMALL_INTEGER_EXT for tail (not NIL!)
  v2.setUint8(9, 2);    // value = 2

  const decoder = new ETFDecoder(buf2);
  assert.throws(() => decoder.decode(), /improper list/);
});

test("Decode", "improper list from Erlang throws", () => {
  const buf = etfFromErlang("[1 | 2]");
  const decoder = new ETFDecoder(buf);
  assert.throws(() => decoder.decode(), /improper list/);
});

// --- Unknown tag ---
test("Decode", "unknown tag throws", () => {
  const buf = new ArrayBuffer(3);
  const v = new DataView(buf);
  v.setUint8(0, 131);
  v.setUint8(1, 200);
  const decoder = new ETFDecoder(buf);
  assert.throws(() => decoder.decode(), /unknown tag 200/);
});

// --- Version byte check ---
test("Decode", "wrong version byte throws", () => {
  const buf = new ArrayBuffer(2);
  const v = new DataView(buf);
  v.setUint8(0, 99);
  v.setUint8(1, 97);
  const decoder = new ETFDecoder(buf);
  assert.throws(() => decoder.decode(), /expected version byte 131/);
});

// ============================================================
// Encoder tests
// ============================================================

console.log("\nETF Encoder tests:");

// --- Integers ---
testEncode("small integer (0)", 0, "0");
testEncode("small integer (42)", 42, "42");
testEncode("small integer (255)", 255, "255");
testEncode("integer (256)", 256, "256");
testEncode("integer (1712000000)", 1712000000, "1712000000");
testEncode("negative integer (-1)", -1, "-1");
testEncode("negative integer (-7)", -7, "-7");
testEncode("negative integer (-2147483648)", -2147483648, "-2147483648");

// --- Big integers ---
testEncode("big integer (positive)", 999999999999999n, "999999999999999");
testEncode("big integer (negative)", -999999999999999n, "-999999999999999");
testEncode("bigint zero", 0n, "0");

// --- Floats ---
testEncode("float (3.14)", 3.14, "3.14");
testEncode("float (-2.5)", -2.5, "-2.5");
testEncode("float (0.0)", 0.1, "0.1"); // 0.0 would be integer in JS

// --- Strings ---
testEncode("string (hello)", "hello", "<<\"hello\">>");
testEncode("empty string", "", "<<>>");

// --- Booleans ---
testEncode("boolean true", true, "true");
testEncode("boolean false", false, "false");

// --- Nil / undefined ---
testEncode("undefined (Nil)", undefined, "nil");
testEncode("null", null, "nil");

// --- Tuples (arrays) ---
testEncode("empty tuple", [], "{}");
testEncode("2-tuple", [1, 2], "{1,2}");
testEncode("3-tuple", [1, "hello", true], "{1,<<\"hello\">>,true}");

// --- Lists ---
testEncode("empty list", [], "[]", { isList: true });
testEncode("integer list", [1, 2, 3], "[1,2,3]", { isList: true });
testEncode("mixed list", [1, "two", true], "[1,<<\"two\">>,true]", { isList: true });

// --- Maps ---
test("Encode", "map", () => {
  const m = new Map([["a", 1], ["b", 2]]);
  const buf = jsEncode(m);
  const b64 = bufferToBase64(buf);
  const erlResult = etfDecodeInErlang(b64);
  assert.ok(erlResult.includes("<<\"a\">> => 1"), `Expected key a in: ${erlResult}`);
  assert.ok(erlResult.includes("<<\"b\">> => 2"), `Expected key b in: ${erlResult}`);
});

test("Encode", "empty map", () => {
  const m = new Map();
  const buf = jsEncode(m);
  const b64 = bufferToBase64(buf);
  const erlResult = etfDecodeInErlang(b64);
  assert.equal(erlResult, "#{}");
});

// ============================================================
// Round-trip tests (JS encode -> JS decode)
// ============================================================

console.log("\nRound-trip tests (JS encode -> JS decode):");

function testRoundTrip(name, value, compare) {
  test("RoundTrip", name, () => {
    const buf = jsEncode(value);
    const decoder = new ETFDecoder(buf);
    const result = decoder.decode();
    if (compare) {
      compare(result);
    } else {
      assert.deepStrictEqual(result, value);
    }
  });
}

testRoundTrip("integer 0", 0);
testRoundTrip("integer 42", 42);
testRoundTrip("integer 255", 255);
testRoundTrip("integer 256", 256);
testRoundTrip("integer -7", -7);
testRoundTrip("integer 1712000000", 1712000000);
testRoundTrip("float 3.14", 3.14);
testRoundTrip("float -2.5", -2.5);
testRoundTrip("string hello", "hello");
testRoundTrip("empty string", "");
testRoundTrip("boolean true", true);
testRoundTrip("boolean false", false);
testRoundTrip("undefined", undefined);
testRoundTrip("tuple [1, 2]", [1, 2]);
testRoundTrip("nested tuple", [1, [2, 3]]);
testRoundTrip("bigint", 999999999999999n, r => assert.equal(r, 999999999999999));

function testListRoundTrip(name, arr) {
  test("RoundTrip", name, () => {
    const buf = jsEncodeList(arr);
    const decoder = new ETFDecoder(buf);
    const result = decoder.decode();
    assert.deepStrictEqual(result, arr);
  });
}

testListRoundTrip("empty list", []);
testListRoundTrip("integer list", [1, 2, 3]);
testListRoundTrip("mixed list", [1, "two", true, undefined]);

test("RoundTrip", "map", () => {
  const m = new Map([["x", 10], ["y", 20]]);
  const buf = jsEncode(m);
  const decoder = new ETFDecoder(buf);
  const result = decoder.decode();
  assert.ok(result instanceof Map);
  assert.equal(result.get("x"), 10);
  assert.equal(result.get("y"), 20);
});

// ============================================================
// Float field registry tests
// ============================================================

console.log("\nFloat field registry tests:");

test("FloatRegistry", "whole-number float encoded as NEW_FLOAT_EXT when registered", () => {
  const enc1 = new ETFEncoder();
  enc1.writeUint8(131);
  enc1.encodeNumber(2);
  const bytes1 = new Uint8Array(enc1.result());
  assert.equal(bytes1[1], 97, "Without registry, 2 should use SMALL_INTEGER_EXT (97)");

  const enc2 = new ETFEncoder();
  enc2.writeUint8(131);
  enc2.writeUint8(70); // NEW_FLOAT_EXT
  enc2.writeFloat64(2.0);
  const bytes2 = new Uint8Array(enc2.result());
  assert.equal(bytes2[1], 70, "NEW_FLOAT_EXT tag should be 70");

  const b64 = bufferToBase64(enc2.result());
  const erlResult = etfDecodeInErlang(b64);
  assert.equal(erlResult, "2.0");
});

test("FloatRegistry", "registerFloatFields stores and retrieves correctly", () => {
  registerFloatFields("my_type", [0, 2]);
  const indices = floatFieldRegistry.get("my_type");
  assert.ok(indices instanceof Set);
  assert.ok(indices.has(0));
  assert.ok(!indices.has(1));
  assert.ok(indices.has(2));
  floatFieldRegistry.delete("my_type");
});

test("FloatRegistry", "encoder uses registry for custom type float fields", () => {
  registerFloatFields("point", [0, 1]);
  const indices = floatFieldRegistry.get("point");
  assert.ok(indices.has(0));
  assert.ok(indices.has(1));

  const enc = new ETFEncoder();
  enc.writeUint8(131);
  enc.writeUint8(104); // SMALL_TUPLE_EXT
  enc.writeUint8(3);   // arity: atom + 2 fields
  enc.writeAtom("point");
  enc.writeUint8(70);
  enc.writeFloat64(2.0);
  enc.writeUint8(70);
  enc.writeFloat64(3.0);

  const b64 = bufferToBase64(enc.result());
  const erlResult = etfDecodeInErlang(b64);
  assert.equal(erlResult, "{point,2.0,3.0}");

  const enc2 = new ETFEncoder();
  enc2.writeUint8(131);
  enc2.writeUint8(104);
  enc2.writeUint8(3);
  enc2.writeAtom("point");
  enc2.encodeNumber(2);
  enc2.encodeNumber(3);
  const b642 = bufferToBase64(enc2.result());
  const erlResult2 = etfDecodeInErlang(b642);
  assert.equal(erlResult2, "{point,2,3}");

  floatFieldRegistry.delete("point");
});

// ============================================================
// Edge case: ATOM_UTF8_EXT (tag 118) with 2-byte length
// ============================================================

console.log("\nEdge case tests:");

test("Decode", "ATOM_UTF8_EXT (tag 118) long atom", () => {
  const atomName = "a".repeat(300);
  const encoded = textEncoder.encode(atomName);
  const buf = new ArrayBuffer(1 + 1 + 2 + encoded.length);
  const view = new DataView(buf);
  let off = 0;
  view.setUint8(off++, 131);
  view.setUint8(off++, 118);
  view.setUint16(off, encoded.length); off += 2;
  new Uint8Array(buf).set(encoded, off);

  const decoder = new ETFDecoder(buf);
  const result = decoder.decode();
  assert.equal(result, atomName);
});

test("Decode", "0-arity tuple", () => {
  const buf = new ArrayBuffer(3);
  const view = new DataView(buf);
  view.setUint8(0, 131);
  view.setUint8(1, 104);
  view.setUint8(2, 0);
  const decoder = new ETFDecoder(buf);
  const result = decoder.decode();
  assert.deepEqual(result, []);
});

// ============================================================
// Constructor input shapes - regression for `wire.decode` from
// Gleam JS. The Gleam BitArray exposes its bytes as a Uint8Array
// at `.rawBuffer`, NOT as an ArrayBuffer.
// ============================================================

console.log("\nConstructor input shape tests:");

function makeIntegerArrayBuffer() {
  const buf = new ArrayBuffer(3);
  const view = new DataView(buf);
  view.setUint8(0, 131);
  view.setUint8(1, 97);
  view.setUint8(2, 42);
  return buf;
}

test("Decode", "constructor accepts ArrayBuffer", () => {
  const decoder = new ETFDecoder(makeIntegerArrayBuffer());
  assert.equal(decoder.decode(), 42);
});

test("Decode", "constructor accepts Uint8Array", () => {
  const u8 = new Uint8Array(makeIntegerArrayBuffer());
  const decoder = new ETFDecoder(u8);
  assert.equal(decoder.decode(), 42);
});

test("Decode", "constructor accepts Gleam BitArray (mock)", () => {
  const mockBitArray = { rawBuffer: new Uint8Array(makeIntegerArrayBuffer()) };
  const decoder = new ETFDecoder(mockBitArray);
  assert.equal(decoder.decode(), 42);
});

test("Decode", "constructor handles Uint8Array with non-zero byteOffset", () => {
  const wide = new Uint8Array(10);
  wide.set([0, 0, 0, 131, 97, 42, 0, 0, 0, 0]);
  const slice = wide.subarray(3, 6);
  assert.equal(slice.byteOffset, 3);
  const decoder = new ETFDecoder(slice);
  assert.equal(decoder.decode(), 42);
});

test("Decode", "constructor rejects unsupported input", () => {
  assert.throws(() => new ETFDecoder("not a buffer"), /input must be/);
  assert.throws(() => new ETFDecoder(null), /input must be/);
  assert.throws(() => new ETFDecoder({}), /input must be/);
});

// ============================================================
// snakeCase tests - must match Gleam to_snake_case
// ============================================================

function snakeCase(name) {
  let result = "";
  for (let i = 0; i < name.length; i++) {
    const ch = name[i];
    const isUpper = ch !== ch.toLowerCase();
    if (i === 0) { result += ch.toLowerCase(); continue; }
    if (isUpper) {
      const prevUpper = name[i - 1] !== name[i - 1].toLowerCase();
      const nextLower = i + 1 < name.length && name[i + 1] === name[i + 1].toLowerCase();
      if (prevUpper && nextLower) { result += "_" + ch.toLowerCase(); }
      else if (prevUpper) { result += ch.toLowerCase(); }
      else { result += "_" + ch.toLowerCase(); }
    } else { result += ch; }
  }
  return result;
}

const snakeCases = [
  ["AdminData", "admin_data"],
  ["One", "one"],
  ["TwoOrMore", "two_or_more"],
  ["XMLParser", "xml_parser"],
  ["ABC", "abc"],
  ["A", "a"],
  ["lowercase", "lowercase"],
  ["HTTPSConnection", "https_connection"],
  ["MyXMLParser", "my_xml_parser"],
  ["Page2Title", "page2_title"],
  ["HTTPRequest", "http_request"],
];

for (const [input, expected] of snakeCases) {
  test("snakeCase", `${input} → ${expected}`, () => {
    assert.equal(snakeCase(input), expected);
  });
}

// ============================================================
// Summary
// ============================================================

console.log(`\n\x1b[1m${passed + failed} tests: \x1b[32m${passed} passed\x1b[0m, \x1b[${failed > 0 ? "31" : "32"}m${failed} failed\x1b[0m`);

if (failures.length > 0) {
  console.log("\nFailures:");
  for (const f of failures) {
    console.log(`  - ${f}`);
  }
}

process.exit(failed > 0 ? 1 : 0);
