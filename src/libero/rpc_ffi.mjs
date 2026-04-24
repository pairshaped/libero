// @ts-check
//
// ETF wire format for libero RPC.
//
// Wire shape: Erlang External Term Format (ETF), subset used by Gleam.
// WebSocket uses binary frames (ArrayBuffer).
//
// Gleam lists are rebuilt as linked lists so `gleam/list` operations
// work on them. Custom type decoding is handled by the typed decoder
// generated per consumer (rpc_decoders_ffi.mjs).

import { getMsgFromServerDecoder } from "./decoders_prelude.mjs";
import { Ok, Error as ResultError, CustomType, Empty, NonEmpty, BitArray } from "../../gleam_stdlib/gleam.mjs";
import { Some, None } from "../../gleam_stdlib/gleam/option.mjs";
import { from_list as dictFromList } from "../../gleam_stdlib/gleam/dict.mjs";
import { InternalError, AppError, MalformedRequest, UnknownFunction } from "./error.mjs";

// ---------- Error names ----------
//
// Error.name values set on exceptions thrown by the codec. Consumers
// that need to branch on failure mode can match `err.name === ERROR_X`
// instead of parsing message strings.

/** Input to ETFDecoder is not a supported buffer type. */
export const ERROR_INVALID_INPUT = "ETF_INVALID_INPUT";
/** First byte is not the ETF version tag (131). */
export const ERROR_VERSION_BYTE = "ETF_VERSION_BYTE";
/** Encountered a tag the decoder does not support. */
export const ERROR_UNKNOWN_TAG = "ETF_UNKNOWN_TAG";
/** List tail is not NIL_EXT. Gleam cannot produce improper lists. */
export const ERROR_IMPROPER_LIST = "ETF_IMPROPER_LIST";
/** Atom name exceeds the Erlang 255 codepoint limit. */
export const ERROR_ATOM_TOO_LONG = "ETF_ATOM_TOO_LONG";

/**
 * @param {string} message
 * @param {string} name
 * @returns {Error}
 */
function makeError(message, name) {
  const e = new Error(message);
  e.name = name;
  return e;
}

// ---------- Identity helper (for Gleam FFI) ----------

/**
 * @template T
 * @param {T} x
 * @returns {T}
 */
export function identity(x) {
  return x;
}

// ---------- Float field registry ----------
//
// JS has no int/float distinction - `2.0 === 2` and
// `Number.isInteger(2.0) === true`. But ETF does distinguish them,
// and Gleam's BEAM runtime treats Int and Float as different types.
//
// The generator discovers which constructor fields are typed as Float
// and emits registerFloatFields() calls. The ETF encoder checks this
// registry when encoding custom type fields, ensuring whole-number
// floats like `2.0` are encoded as NEW_FLOAT_EXT (tag 70) instead of
// INTEGER_EXT (tags 97/98).
//
// This is ETF-specific metadata - a JSON encoder would ignore it
// since JSON has only one number type.

/** @type {Map<string, Set<number>>} */
const floatFieldRegistry = new Map();

/**
 * Register which field indices of a custom-type atom should be encoded
 * as floats regardless of whether the JS value is a whole number.
 * @param {string} atomName snake_case constructor name
 * @param {number[]} fieldIndices 0-based positions of Float-typed fields
 */
export function registerFloatFields(atomName, fieldIndices) {
  floatFieldRegistry.set(atomName, new Set(fieldIndices));
}

/**
 * Build a Gleam linked list from a plain JS array.
 * @param {any[]} arr
 * @returns {any}
 */
function arrayToGleamList(arr) {
  let list = new Empty();
  for (let i = arr.length - 1; i >= 0; i--) {
    list = new NonEmpty(arr[i], list);
  }
  return list;
}

/**
 * Flatten a Gleam linked list (or JS array) into a plain JS array.
 * @param {any} list
 * @returns {any[]}
 */
function gleamListToArray(list) {
  if (Array.isArray(list)) return list;
  const out = [];
  let cur = list;
  while (cur instanceof NonEmpty) {
    out.push(cur.head);
    cur = cur.tail;
  }
  return out;
}

// ---------- ETF Decoder ----------
//
// Design note: no wrapper classes for atoms or tuples.
//
// A general-purpose ETF decoder (e.g. arnu515/erlang-etf.js — see
// https://github.com/arnu515/erlang-etf.js, MIT) wraps atoms in `Atom`
// and tuples in `Tuple` because, in raw JS, atoms collide with
// binaries (both are strings) and tuples collide with lists (both are
// arrays). Without wrappers, the consumer can't tell `:ok` from
// `<<"ok">>` or `{1, 2}` from `[1, 2]`.
//
// Libero doesn't need wrappers because the typed decoder layer
// (rpc_decoders_ffi.mjs, generated per consumer) knows the expected
// shape from the Gleam type graph. When raw mode hands back
// `["some", 42]`, the typed decoder sees an `Option(Int)` field at that
// position and constructs `_Some(42)`. Same for atoms-vs-binaries: the
// type tells the decoder which one to expect.
//
// Adding wrapper classes here would just be one more layer the typed
// decoder unwraps. The cost is that raw mode is ambiguous on its own —
// fine for libero, but the reason a future standalone ETF library
// (split from this codec) would need wrappers.
//
// Prior art: libero's codec is independently implemented, but aligns
// with erlang-etf.js on BIT_BINARY_EXT handling and atom-length
// validation (255 codepoints). Credit to that project for the spec
// references.

const utf8Decoder = new TextDecoder();

/**
 * @typedef {ArrayBuffer | Uint8Array | { rawBuffer: Uint8Array }} DecoderInput
 */

class ETFDecoder {
  /**
   * @param {DecoderInput} input ArrayBuffer, Uint8Array, or Gleam BitArray
   * @param {boolean} [raw] if true, atoms stay as strings and tagged
   *   tuples stay as plain JS arrays. Used when the typed decoder
   *   will re-interpret the result.
   */
  constructor(input, raw = false) {
    // Accept any of: ArrayBuffer (WebSocket onmessage with binaryType
    // "arraybuffer"), Uint8Array, or a Gleam JS BitArray (which exposes
    // its bytes as `rawBuffer`, a Uint8Array). Normalising here lets the
    // public `wire.decode` primitive take a Gleam BitArray directly,
    // matching the cross-target promise of the Gleam-side function.
    /** @type {Uint8Array} */
    let bytes;
    if (input instanceof Uint8Array) {
      bytes = input;
    } else if (input instanceof ArrayBuffer) {
      bytes = new Uint8Array(input);
    } else if (input && /** @type {any} */ (input).rawBuffer instanceof Uint8Array) {
      bytes = /** @type {any} */ (input).rawBuffer;
    } else {
      throw makeError(
        "ETFDecoder: input must be ArrayBuffer, Uint8Array, or Gleam BitArray",
        ERROR_INVALID_INPUT,
      );
    }
    this.bytes = bytes;
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    this.offset = 0;
    this.raw = raw;
  }

  /** @returns {any} */
  decode() {
    const version = this.readUint8();
    if (version !== 131) {
      throw makeError(
        `ETF decode: expected version byte 131, got ${version}`,
        ERROR_VERSION_BYTE,
      );
    }
    return this.decodeTerm();
  }

  ensureAvailable(n) {
    if (this.offset + n > this.bytes.byteLength) {
      throw makeError(
        `ETF decode: need ${n} bytes at offset ${this.offset}, only ${this.bytes.byteLength - this.offset} available`,
        "ETF_TRUNCATED",
      );
    }
  }

  readUint8() {
    this.ensureAvailable(1);
    const v = this.view.getUint8(this.offset);
    this.offset += 1;
    return v;
  }

  readUint16() {
    this.ensureAvailable(2);
    const v = this.view.getUint16(this.offset);
    this.offset += 2;
    return v;
  }

  readUint32() {
    this.ensureAvailable(4);
    const v = this.view.getUint32(this.offset);
    this.offset += 4;
    return v;
  }

  readInt32() {
    this.ensureAvailable(4);
    const v = this.view.getInt32(this.offset);
    this.offset += 4;
    return v;
  }

  readFloat64() {
    this.ensureAvailable(8);
    const v = this.view.getFloat64(this.offset);
    this.offset += 8;
    return v;
  }

  readBytes(n) {
    this.ensureAvailable(n);
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
      case 70: // NEW_FLOAT_EXT
        return this.readFloat64();

      case 97: // SMALL_INTEGER_EXT
        return this.readUint8();

      case 98: // INTEGER_EXT
        return this.readInt32();

      case 104: // SMALL_TUPLE_EXT
        return this.decodeTuple(this.readUint8());

      case 105: // LARGE_TUPLE_EXT
        return this.decodeTuple(this.readUint32());

      case 106: // NIL_EXT (empty list)
        if (this.raw) return [];
        return arrayToGleamList([]);

      case 108: // LIST_EXT
        return this.decodeList();

      case 107: { // STRING_EXT (list of small ints encoded as bytes)
        // Erlang optimizes lists of bytes (0-255) into this compact form.
        // Decode as a Gleam List(Int) - same semantics as LIST_EXT of SMALL_INTEGER_EXT.
        const len = this.readUint16();
        const elements = [];
        for (let i = 0; i < len; i++) {
          elements.push(this.readUint8());
        }
        if (this.raw) return elements;
        return arrayToGleamList(elements);
      }

      case 109: // BINARY_EXT (Gleam string)
        return this.readString(this.readUint32());

      case 110: // SMALL_BIG_EXT
        return this.decodeBigInt(this.readUint8());

      case 111: // LARGE_BIG_EXT
        return this.decodeBigInt(this.readUint32());

      case 116: // MAP_EXT
        return this.decodeMap();

      case 118: // ATOM_UTF8_EXT
        return this.decodeAtom(this.readUint16());

      case 119: // SMALL_ATOM_UTF8_EXT
        return this.decodeAtom(this.readUint8());

      case 77: { // BIT_BINARY_EXT (non-byte-aligned binary)
        // len bytes, then 1 byte for "bits in last byte" (1-8).
        // The last byte's high `bits` bits are meaningful; low `8 - bits`
        // bits are padding. A Gleam BitArray represents this natively
        // via bitSize, so no separate wrapper is needed.
        const len = this.readUint32();
        const bitsInLastByte = this.readUint8();
        const bytes = this.readBytes(len);
        const bitSize = len === 0 ? 0 : (len - 1) * 8 + bitsInLastByte;
        return new BitArray(bytes, bitSize, 0);
      }

      default:
        throw makeError(
          `ETF decode: unknown tag ${tag} at offset ${this.offset - 1}`,
          ERROR_UNKNOWN_TAG,
        );
    }
  }

  // DESIGN NOTE: No atom count limit on the JS side (unlike Erlang's [safe]
  // flag). This is acceptable because: (1) the server is the only sender and
  // it encodes well-typed Gleam values, (2) the WebSocket server (mist) can
  // enforce frame size limits, and (3) the typed decoder layer rejects
  // unknown constructors. A standalone ETF library should add a limit.
  decodeAtom(len) {
    const name = this.readString(len);
    // Erlang's hard limit is 255 codepoints (not bytes). UTF-8 codepoints
    // are 1-4 bytes, so a byte length under 256 can still produce <= 255
    // codepoints — but ATOM_UTF8_EXT (uint16 length) can exceed this.
    let codepointCount = 0;
    for (const _ of name) {
      codepointCount++;
      if (codepointCount >= 256) {
        throw makeError(
          "ETF decode: atom name exceeds 255 codepoints",
          ERROR_ATOM_TOO_LONG,
        );
      }
    }
    // Special atoms
    if (name === "true") return true;
    if (name === "false") return false;
    if (name === "nil" || name === "undefined") return undefined;
    // Return atom as string - typed decoder resolves constructors.
    return name;
  }

  decodeTuple(arity) {
    if (arity === 0) return [];

    // Peek at first element to check for atom tag
    const firstTag = this.bytes[this.offset];
    if (firstTag === 118 || firstTag === 119) {
      // First element is an atom - read the atom name directly
      this.offset += 1; // skip the tag byte
      const atomLen = firstTag === 119 ? this.readUint8() : this.readUint16();
      const atomName = this.readString(atomLen);

      // Special atoms in tuple position: treat as plain values
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

    // Not atom-tagged - decode all elements as plain JS array (Gleam tuple)
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
    // Read the tail - must be NIL_EXT (106) for proper lists.
    // Gleam cannot produce improper lists, so a non-nil tail indicates
    // corrupted data or a non-Gleam sender.
    const tailTag = this.readUint8();
    if (tailTag !== 106) {
      throw makeError(
        "ETF decode: improper list (non-nil tail) - Gleam cannot produce these",
        ERROR_IMPROPER_LIST,
      );
    }
    if (this.raw) return elements;
    return arrayToGleamList(elements);
  }

  decodeBigInt(n) {
    const sign = this.readUint8();
    const digits = this.readBytes(n);
    // Reconstruct the integer from little-endian digits
    let value = 0n;
    for (let i = n - 1; i >= 0; i--) {
      value = (value << 8n) | BigInt(digits[i]);
    }
    if (sign === 1) value = -value;
    // If it fits in a regular JS number, return as Number
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
    if (this.raw) return pairs;
    return dictFromList(arrayToGleamList(pairs));
  }
}

// ---------- ETF Encoder ----------

const textEncoder = new TextEncoder();

class ETFEncoder {
  constructor() {
    // Start with 1024 bytes, grow as needed.
    this.buffer = new ArrayBuffer(1024);
    this.view = new DataView(this.buffer);
    this.bytes = new Uint8Array(this.buffer);
    this.offset = 0;
  }

  /** @param {number} needed */
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

  /** @param {number} v */
  writeUint8(v) {
    this.ensureCapacity(1);
    this.view.setUint8(this.offset, v);
    this.offset += 1;
  }

  /** @param {number} v */
  writeUint16(v) {
    this.ensureCapacity(2);
    this.view.setUint16(this.offset, v);
    this.offset += 2;
  }

  /** @param {number} v */
  writeUint32(v) {
    this.ensureCapacity(4);
    this.view.setUint32(this.offset, v);
    this.offset += 4;
  }

  /** @param {number} v */
  writeInt32(v) {
    this.ensureCapacity(4);
    this.view.setInt32(this.offset, v);
    this.offset += 4;
  }

  /** @param {number} v */
  writeFloat64(v) {
    this.ensureCapacity(8);
    this.view.setFloat64(this.offset, v);
    this.offset += 8;
  }

  /** @param {Uint8Array} bytes */
  writeBytes(bytes) {
    this.ensureCapacity(bytes.length);
    this.bytes.set(bytes, this.offset);
    this.offset += bytes.length;
  }

  /** @returns {ArrayBuffer} */
  result() {
    return this.buffer.slice(0, this.offset);
  }

  /** @param {any} value */
  encodeTerm(value) {
    if (value === undefined || value === null) {
      // Gleam Nil → atom "nil"
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

    // JS array = Gleam tuple
    if (Array.isArray(value)) {
      this.encodeTuple(value);
      return;
    }

    // Gleam linked list
    if (value instanceof Empty || value instanceof NonEmpty) {
      const arr = gleamListToArray(value);
      this.encodeList(arr);
      return;
    }

    // Gleam Dict (JS Map).
    // Gleam Dict compiles to JS Map (gleam_stdlib convention).
    // If gleam_stdlib changes this, the encoder will throw "unsupported type"
    // which makes the issue immediately visible.
    if (value instanceof Map) {
      this.encodeMap(value);
      return;
    }

    // Gleam BitArray (has rawBuffer: Uint8Array).
    // Uses BINARY_EXT (tag 109) for all BitArrays. Sub-byte-aligned
    // BitArrays (bitSize % 8 != 0) should technically use BIT_BINARY_EXT
    // (tag 77), but Gleam's stdlib BitArray is always byte-aligned in
    // practice. The decoder handles BIT_BINARY_EXT correctly for
    // interop with Erlang values that use it.
    if (value && value.rawBuffer instanceof Uint8Array) {
      if (value.bitSize !== undefined && value.bitSize % 8 !== 0) {
        // Sub-byte-aligned: use BIT_BINARY_EXT (tag 77) to preserve
        // trailing bit count. Without this, the Erlang side would
        // receive a byte-aligned binary, losing the trailing bits.
        const byteLen = value.rawBuffer.length;
        const bitsInLastByte = value.bitSize % 8;
        this.writeUint8(77); // BIT_BINARY_EXT
        this.writeUint32(byteLen);
        this.writeUint8(bitsInLastByte);
        this.writeBytes(value.rawBuffer);
      } else {
        this.writeUint8(109); // BINARY_EXT
        this.writeUint32(value.rawBuffer.length);
        this.writeBytes(value.rawBuffer);
      }
      return;
    }

    // Gleam custom type instance
    if (value instanceof CustomType) {
      const ctorName = snakeCase(value.constructor.name);
      const keys = Object.keys(value);
      if (keys.length === 0) {
        // 0-arity constructor → bare atom
        this.writeAtom(ctorName);
      } else {
        // N-arity constructor → tuple {atom, field1, field2, ...}
        const arity = keys.length + 1;
        if (arity <= 255) {
          this.writeUint8(104); // SMALL_TUPLE_EXT
          this.writeUint8(arity);
        } else {
          this.writeUint8(105); // LARGE_TUPLE_EXT
          this.writeUint32(arity);
        }
        this.writeAtom(ctorName);
        // Check float field registry - fields at registered indices
        // must be encoded as floats even if Number.isInteger is true.
        const floatIndices = floatFieldRegistry.get(ctorName);
        keys.forEach((k, i) => {
          const fieldValue = value[k];
          if (floatIndices && floatIndices.has(i)
              && typeof fieldValue === "number") {
            this.writeUint8(70); // NEW_FLOAT_EXT
            this.writeFloat64(fieldValue);
          } else {
            this.encodeTerm(fieldValue);
          }
        });
      }
      return;
    }

    // Fallback: this indicates a bug in the calling code — all Gleam
    // types should be handled above. Throw rather than silently
    // producing "[object Object]" which would be a corrupt payload.
    throw new Error(
      "ETF encode: unsupported value type: " + typeof value +
      " (" + String(value) + ")"
    );
  }

  writeAtom(name) {
    const encoded = textEncoder.encode(name);
    if (encoded.length <= 255) {
      this.writeUint8(119); // SMALL_ATOM_UTF8_EXT
      this.writeUint8(encoded.length);
    } else {
      this.writeUint8(118); // ATOM_UTF8_EXT
      this.writeUint16(encoded.length);
    }
    this.writeBytes(encoded);
  }

  encodeBinary(str) {
    const encoded = textEncoder.encode(str);
    this.writeUint8(109); // BINARY_EXT
    this.writeUint32(encoded.length);
    this.writeBytes(encoded);
  }

  encodeNumber(n) {
    if (Number.isInteger(n)) {
      if (n >= 0 && n <= 255) {
        this.writeUint8(97); // SMALL_INTEGER_EXT
        this.writeUint8(n);
      } else if (n >= -2147483648 && n <= 2147483647) {
        this.writeUint8(98); // INTEGER_EXT
        this.writeInt32(n);
      } else {
        // Large integer - use bigint encoding
        this.encodeBigInt(BigInt(n));
      }
    } else {
      this.writeUint8(70); // NEW_FLOAT_EXT
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
      // Zero - encode as SMALL_INTEGER_EXT
      this.writeUint8(97);
      this.writeUint8(0);
      return;
    }
    if (digits.length <= 255) {
      this.writeUint8(110); // SMALL_BIG_EXT
      this.writeUint8(digits.length);
    } else {
      this.writeUint8(111); // LARGE_BIG_EXT
      this.writeUint32(digits.length);
    }
    this.writeUint8(sign);
    this.writeBytes(new Uint8Array(digits));
  }

  encodeTuple(elements) {
    if (elements.length <= 255) {
      this.writeUint8(104); // SMALL_TUPLE_EXT
      this.writeUint8(elements.length);
    } else {
      this.writeUint8(105); // LARGE_TUPLE_EXT
      this.writeUint32(elements.length);
    }
    for (const el of elements) {
      this.encodeTerm(el);
    }
  }

  encodeList(arr) {
    if (arr.length === 0) {
      this.writeUint8(106); // NIL_EXT
      return;
    }
    this.writeUint8(108); // LIST_EXT
    this.writeUint32(arr.length);
    for (const el of arr) {
      this.encodeTerm(el);
    }
    this.writeUint8(106); // NIL_EXT tail
  }

  encodeMap(map) {
    this.writeUint8(116); // MAP_EXT
    this.writeUint32(map.size);
    map.forEach((val, key) => {
      this.encodeTerm(key);
      this.encodeTerm(val);
    });
  }
}

// ---------- Helper ----------

/**
 * Convert PascalCase to snake_case. Mirrors Gleam's `to_snake_case`
 * so runtime encoding and codegen-time atom registration agree.
 * Handles consecutive uppercase: "XMLParser" → "xml_parser",
 * "HTTPSConnection" → "https_connection".
 *
 * Digits are treated as lowercase — no underscore is inserted before
 * a digit run. This matches Gleam's compiler behavior and the Erlang
 * side (walker.to_snake_case). Verified by snake_case_test.gleam.
 * @param {string} name
 * @returns {string}
 */
function snakeCase(name) {
  let result = "";
  for (let i = 0; i < name.length; i++) {
    const ch = name[i];
    const isUpper = ch !== ch.toLowerCase();
    if (i === 0) {
      result += ch.toLowerCase();
      continue;
    }
    if (isUpper) {
      const prevUpper = name[i - 1] !== name[i - 1].toLowerCase();
      const nextLower = i + 1 < name.length
        && name[i + 1] === name[i + 1].toLowerCase();
      if (prevUpper && nextLower) {
        // UPPER→UPPER→lower: start of new word after acronym
        result += "_" + ch.toLowerCase();
      } else if (prevUpper) {
        // UPPER→UPPER→(UPPER|end): still in acronym
        result += ch.toLowerCase();
      } else {
        // lower→UPPER: normal camelCase boundary
        result += "_" + ch.toLowerCase();
      }
    } else {
      result += ch;
    }
  }
  return result;
}

// ---------- Public codec API ----------

/**
 * Encode a standalone Gleam value to an ETF binary. Used by the
 * public `libero.wire.encode` function. Unlike `encode_call`, there
 * is no envelope — the result is the raw ETF encoding of a single
 * value. Intended for non-RPC paths like passing state into a
 * Lustre SPA via init flags.
 * @param {any} value
 * @returns {BitArray}
 */
export function encode_value(value) {
  const encoder = new ETFEncoder();
  encoder.writeUint8(131); // ETF version byte
  encoder.encodeTerm(value);
  return new BitArray(new Uint8Array(encoder.result()));
}

/**
 * Decode a standalone Gleam value from an ETF binary. Symmetric with
 * `encode_value`. Custom type reconstruction is handled by the typed
 * decoder (rpc_decoders_ffi.mjs).
 * @param {DecoderInput} buffer
 * @returns {any}
 */
export function decode_value(buffer) {
  const decoder = new ETFDecoder(buffer);
  return decoder.decode();
}

/**
 * Raw variant of `decode_value`: atoms stay as strings and tagged
 * tuples stay as plain JS arrays. Used internally when the typed
 * decoder (decode_msg_from_server) will re-interpret the result.
 * @param {DecoderInput} buffer
 * @returns {any}
 */
export function decode_value_raw(buffer) {
  const decoder = new ETFDecoder(buffer, true);
  return decoder.decode();
}

// Gleam's wire.DecodeError(message) custom type.
// Must extend CustomType so Gleam pattern matching works.
class WireDecodeError extends CustomType {
  /** @param {string} message */
  constructor(message) {
    super();
    this.message = message;
    this[0] = message;
  }
}

/**
 * Safe variant of `decode_value` that returns a Result instead of
 * throwing. Used by the public `libero.wire.decode_safe` function.
 * @param {DecoderInput} buffer
 * @returns {any} Ok(value) or Error(WireDecodeError)
 */
export function decode_safe(buffer) {
  try {
    const decoder = new ETFDecoder(buffer);
    const value = decoder.decode();
    return new Ok(value);
  } catch (e) {
    const msg = e && /** @type {any} */ (e).message ? /** @type {any} */ (e).message : String(e);
    return new ResultError(new WireDecodeError(msg));
  }
}

// ---------- WebSocket ----------
//
// `send` opens the WebSocket lazily on first call and caches the
// connection. The URL is a compile-time constant from Gleam's
// rpc_config module, so it doesn't change across calls. Sends issued
// before the socket's open event are queued and flushed once it opens.
//
// Server→client frames are tagged with a 1-byte prefix:
//   0x00 = response: <<tag, request_id:32-big, etf_bytes>>
//   0x01 = push: <<tag, etf_bytes>>
//
// Responses are matched by request ID (monotonic counter assigned by
// the client). This allows safe timeout handling without closing the
// WebSocket — late responses for timed-out requests are harmlessly
// dropped since their ID has been removed from the callback Map.
//
// Reconnection is the consumer's responsibility — call send() again
// after a close and the socket will be re-established. Push messages
// arriving between close and reconnect are lost by design; consumers
// needing durable push should implement reconnect-with-replay at the
// application layer.

let ws = null;
let pendingSends = [];    // [{payload, requestId, callback, timer}]
let responseCallbacks = new Map(); // requestId -> {callback, timer}
let nextRequestId = 1;
const REQUEST_TIMEOUT_MS = 30_000;

// Push handler registry: module path → callback
const pushHandlers = new Map();

// Build a connection-error value as a proper Gleam Result(_, RpcError)
// so `wire.coerce` + pattern matching in remote_data.from_response can extract
// the InternalError and read its .message field.
function makeConnectionError(message) {
  return new ResultError(new InternalError("", message));
}

// Reconstruct a Gleam RpcError class instance from a raw ETF-decoded term.
// 0-arity variants arrive as a bare atom string; variants with fields
// arrive as atom-tagged arrays. Wire shape matches libero/error.gleam:
//   "malformed_request"                -> MalformedRequest
//   ["app_error", appErr]              -> AppError(appErr)
//   ["unknown_function", name]         -> UnknownFunction(name)
//   ["internal_error", traceId, msg]   -> InternalError(traceId, msg)
function decodeRpcError(term) {
  if (term === "malformed_request") return new MalformedRequest();
  if (!Array.isArray(term)) {
    return new InternalError("", "Malformed RpcError: " + String(term));
  }
  switch (term[0]) {
    case "app_error": return new AppError(term[1]);
    case "malformed_request": return new MalformedRequest();
    case "unknown_function": return new UnknownFunction(term[1]);
    case "internal_error": return new InternalError(term[1], term[2]);
    default:
      return new InternalError("", "Unknown RpcError variant: " + String(term[0]));
  }
}

function clearAllPending(reason) {
  const error = makeConnectionError(reason);
  for (const entry of pendingSends) {
    if (entry.timer) clearTimeout(entry.timer);
    entry.callback(error);
  }
  for (const [, entry] of responseCallbacks) {
    if (entry.timer) clearTimeout(entry.timer);
    entry.callback(error);
  }
  pendingSends = [];
  responseCallbacks = new Map();
}

function ensureSocket(url) {
  if (ws !== null) {
    if (ws.url !== url) {
      throw new Error(
        "Libero only supports a single WebSocket connection. " +
        "Already connected to " + ws.url + ", cannot connect to " + url,
      );
    }
    return;
  }

  let sock;
  try {
    sock = new WebSocket(url);
  } catch (e) {
    clearAllPending("WebSocket constructor failed: " + (e && e.message ? e.message : String(e)));
    return;
  }
  ws = sock;
  ws.binaryType = "arraybuffer";

  ws.addEventListener("open", () => {
    for (const entry of pendingSends) {
      ws.send(entry.payload);
      responseCallbacks.set(entry.requestId, { callback: entry.callback, timer: entry.timer });
    }
    pendingSends = [];
  });

  ws.addEventListener("message", (event) => {
    const bytes = new Uint8Array(event.data);
    const tag = bytes[0];
    const payload = bytes.slice(1);

    if (tag === 0x01) {
      // Push frame: payload is ETF-encoded {module, MsgFromServer_value}.
      // The typed decoder (registered by rpc_decoders_ffi.mjs at module load)
      // decodes raw bytes and resolves the correct constructor per type.
      const typedDecoder = getMsgFromServerDecoder();
      let decodedModule, decodedValue;
      if (typedDecoder) {
        const raw = decode_value_raw(payload);
        // raw is a 2-element JS array: [moduleName, rawMsgFromServerTerm]
        if (raw && raw[0] !== undefined && raw[1] !== undefined) {
          decodedModule = raw[0];
          decodedValue = typedDecoder(raw[1]);
        }
      } else {
        const decoded = decode_value(payload);
        if (decoded && decoded[0] !== undefined && decoded[1] !== undefined) {
          decodedModule = decoded[0];
          decodedValue = decoded[1];
        }
      }
      if (decodedModule !== undefined && decodedValue !== undefined) {
        const handler = pushHandlers.get(decodedModule);
        if (handler) handler(decodedValue);
      }
      return;
    }

    // Response frame (tag 0x00): extract request ID and match by ID.
    // Frame format: <<0x00, request_id:32-big, etf_bytes>>
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const requestId = view.getUint32(1);
    const responsePayload = bytes.slice(5);

    let decoded;
    const typedDecoder = getMsgFromServerDecoder();
    if (typedDecoder) {
      const raw = decode_value_raw(responsePayload);
      if (Array.isArray(raw) && raw[0] === "ok" && raw[1] !== undefined) {
        const typedVariant = typedDecoder(raw[1]);
        decoded = new Ok(typedVariant);
      } else if (Array.isArray(raw) && raw[0] === "error" && raw[1] !== undefined) {
        decoded = new ResultError(decodeRpcError(raw[1]));
      } else {
        decoded = decode_value(responsePayload);
      }
    } else {
      decoded = decode_value(responsePayload);
    }

    const entry = responseCallbacks.get(requestId);
    if (entry) {
      responseCallbacks.delete(requestId);
      if (entry.timer) clearTimeout(entry.timer);
      entry.callback(decoded);
    }
  });

  ws.addEventListener("close", () => {
    ws = null;
    clearAllPending("WebSocket connection closed");
    // Note: no automatic reconnection. The next send() call will create a
    // new connection via ensureSocket(). However, push handlers registered
    // via registerPushHandler() will silently stop receiving messages until
    // that reconnection happens. Consumers that rely on push should handle
    // reconnection in their app layer (e.g., re-send a subscription message
    // or reload data after ServerResponded triggers a new connection).
  });

  ws.addEventListener("error", () => {
    if (ws) {
      const sock = ws;
      ws = null;
      // Clear pending callbacks immediately so a reconnection via the
      // next send() starts with a clean state. The "close" event fires
      // asynchronously after sock.close(), so without this, a send()
      // call between error and close could queue into stale state.
      clearAllPending("WebSocket error");
      sock.close();
    }
  });
}

/**
 * Send a message and queue a callback for the server's response.
 * Responses are matched by request ID. Each request has a 30-second
 * timeout — if no response arrives, the callback receives an
 * InternalError so the UI doesn't hang indefinitely.
 * @param {string} url WebSocket URL (typically from rpc_config)
 * @param {string} module shared module path (e.g. "shared/messages")
 * @param {any} msg the typed MsgFromClient value to encode and send
 * @param {(result: any) => void} callback invoked with the decoded Result
 */
export function send(url, module, msg, callback) {
  ensureSocket(url);
  const requestId = nextRequestId++;
  const payload = encode_call(module, requestId, msg);

  const timer = setTimeout(() => {
    // Remove from whichever state this request is in.
    const pendingIdx = pendingSends.findIndex(e => e.requestId === requestId);
    if (pendingIdx !== -1) {
      pendingSends.splice(pendingIdx, 1);
    }
    responseCallbacks.delete(requestId);
    callback(makeConnectionError("Request timed out"));
    // No need to close the WebSocket — request IDs prevent FIFO desync.
  }, REQUEST_TIMEOUT_MS);

  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(payload);
    responseCallbacks.set(requestId, { callback, timer });
  } else {
    pendingSends.push({ payload, requestId, callback, timer });
  }
}

/**
 * Register a push handler for a specific module. When the server
 * sends a push frame tagged with this module path, the callback is
 * invoked with the decoded value.
 * @param {string} module shared module path
 * @param {(value: any) => void} callback
 */
export function registerPushHandler(module, callback) {
  pushHandlers.set(module, callback);
}

/**
 * Encode a call envelope: `{module_name, request_id, msg}` as ETF binary.
 * Symmetric with the server-side `wire.decode_call`. Returns a raw
 * ArrayBuffer (not a Gleam BitArray) because this is only called
 * internally by `send()`, which passes it directly to `WebSocket.send()`.
 * Compare with `encode_value()` which returns a BitArray for Gleam callers.
 * @param {string} module
 * @param {number} requestId
 * @param {any} msg
 * @returns {ArrayBuffer}
 */
export function encode_call(module, requestId, msg) {
  const encoder = new ETFEncoder();
  encoder.writeUint8(131); // ETF version byte
  // Envelope: {<<"module_name">>, request_id, msg_value}
  encoder.writeUint8(104); // SMALL_TUPLE_EXT
  encoder.writeUint8(3);   // arity 3
  encoder.encodeBinary(module);
  encoder.encodeTerm(requestId);
  encoder.encodeTerm(msg);
  return encoder.result();
}
