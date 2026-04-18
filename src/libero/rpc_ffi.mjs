// ETF wire format for libero RPC.
//
// Wire shape: Erlang External Term Format (ETF), subset used by Gleam.
// WebSocket uses binary frames (ArrayBuffer).
//
// Gleam lists are rebuilt as linked lists so `gleam/list` operations
// work on them. Custom type decoding is handled by the typed decoder
// generated per consumer (rpc_decoders_ffi.mjs).

import { getMsgFromServerDecoder } from "./decoders_prelude.mjs";
import { Ok, Error as ResultError, CustomType, Empty, NonEmpty } from "../../gleam_stdlib/gleam.mjs";
import { Some, None } from "../../gleam_stdlib/gleam/option.mjs";
import { from_list as dictFromList } from "../../gleam_stdlib/gleam/dict.mjs";

// ---------- Identity helper (for Gleam FFI) ----------

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

const floatFieldRegistry = new Map();

export function registerFloatFields(atomName, fieldIndices) {
  floatFieldRegistry.set(atomName, new Set(fieldIndices));
}

function arrayToGleamList(arr) {
  let list = new Empty();
  for (let i = arr.length - 1; i >= 0; i--) {
    list = new NonEmpty(arr[i], list);
  }
  return list;
}

function gleamListToArray(list) {
  if (Array.isArray(list)) return list;
  const out = [];
  let cur = list;
  while (cur && cur.head !== undefined) {
    out.push(cur.head);
    cur = cur.tail;
  }
  return out;
}

// ---------- ETF Decoder ----------

const utf8Decoder = new TextDecoder();

class ETFDecoder {
  // raw=true: atoms stay as strings and tagged tuples stay as plain
  // JS arrays. Used when the typed decoder will re-interpret the result.
  constructor(input, raw = false) {
    // Accept any of: ArrayBuffer (WebSocket onmessage with binaryType
    // "arraybuffer"), Uint8Array, or a Gleam JS BitArray (which exposes
    // its bytes as `rawBuffer`, a Uint8Array). Normalising here lets the
    // public `wire.decode` primitive take a Gleam BitArray directly,
    // matching the cross-target promise of the Gleam-side function.
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
    this.raw = raw;
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

      default:
        throw new Error(`ETF decode: unknown tag ${tag} at offset ${this.offset - 1}`);
    }
  }

  decodeAtom(len) {
    const name = this.readString(len);
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
      throw new Error("ETF decode: improper list (non-nil tail) - Gleam cannot produce these");
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
    const pairsList = this.raw ? pairs : arrayToGleamList(pairs);
    return dictFromList(pairsList);
  }
}

// ---------- ETF Encoder ----------

const textEncoder = new TextEncoder();

class ETFEncoder {
  constructor() {
    // Start with 256 bytes, grow as needed
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
    if (value.head !== undefined || (Empty !== null && value instanceof Empty)) {
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

    // Gleam BitArray (has rawBuffer: Uint8Array)
    if (value && value.rawBuffer instanceof Uint8Array) {
      this.writeUint8(109); // BINARY_EXT
      this.writeUint32(value.rawBuffer.length);
      this.writeBytes(value.rawBuffer);
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

    // Fallback: try to encode as a generic object - shouldn't happen
    // with well-typed Gleam, but encode as a string representation
    this.encodeBinary(String(value));
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

// Convert PascalCase to snake_case. Mirrors the Gleam `to_snake_case`
// algorithm so runtime encoding and codegen-time registration agree.
// Handles consecutive uppercase: "XMLParser" → "xml_parser",
// "HTTPSConnection" → "https_connection".
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

// Encode a standalone Gleam value to an ETF binary. Used by the
// public `libero.wire.encode` function. Unlike `encode_call`, there
// is no envelope - the result is the raw ETF encoding of a single
// value. Intended for non-RPC paths like passing state into a
// Lustre SPA via init flags.
export function encode_value(value) {
  const encoder = new ETFEncoder();
  encoder.writeUint8(131); // ETF version byte
  encoder.encodeTerm(value);
  return encoder.result();
}

// Decode a standalone Gleam value from an ETF binary. Used by the
// public `libero.wire.decode` function. Symmetric with `encode_value`
// above - decodes a single value, not a call envelope. Custom type
// reconstruction is handled by the typed decoder (rpc_decoders_ffi.mjs).
export function decode_value(buffer) {
  const decoder = new ETFDecoder(buffer);
  return decoder.decode();
}

// Raw variant of decode_value: atoms stay as strings and tagged tuples
// stay as plain JS arrays. Used internally when the typed decoder
// (decode_msg_from_server) will re-interpret the result.
export function decode_value_raw(buffer) {
  const decoder = new ETFDecoder(buffer, true);
  return decoder.decode();
}

// Safe variant of decode_value that returns a Result instead of throwing.
// Used by the public `libero.wire.decode_safe` function.
export function decode_safe(buffer) {
  try {
    const decoder = new ETFDecoder(buffer);
    const value = decoder.decode();
    return new Ok(value);
  } catch (e) {
    const msg = e && e.message ? e.message : String(e);
    return new ResultError({ type: "DecodeError", 0: msg });
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
//   0x00 = response (matched to pending callback in FIFO order)
//   0x01 = push (routed to module-specific push handler)
//
// Responses use FIFO matching — no request IDs needed because the
// server processes requests sequentially over a single WebSocket.

let ws = null;
let pendingSends = [];    // [{payload, callback, timer}]
let responseCallbacks = []; // [{callback, timer}]
const REQUEST_TIMEOUT_MS = 30_000;

// Push handler registry: module path → callback
const pushHandlers = new Map();

// Build a connection-error value using imported constructors.
function makeConnectionError(message) {
  return { type: "Error", 0: { type: "InternalError", 0: "", 1: message } };
}

function clearAllPending(reason) {
  const error = makeConnectionError(reason);
  for (const entry of pendingSends) {
    if (entry.timer) clearTimeout(entry.timer);
    entry.callback(error);
  }
  for (const entry of responseCallbacks) {
    if (entry.timer) clearTimeout(entry.timer);
    entry.callback(error);
  }
  pendingSends = [];
  responseCallbacks = [];
}

function ensureSocket(url) {
  if (ws !== null) return;

  ws = new WebSocket(url);
  ws.binaryType = "arraybuffer";

  ws.addEventListener("open", () => {
    for (const entry of pendingSends) {
      ws.send(entry.payload);
      responseCallbacks.push({ callback: entry.callback, timer: entry.timer });
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

    // Response frame (tag 0x00): matched to pending callback in FIFO order.
    // The response wire shape is Result(MsgFromServer.Variant(payload), RpcError).
    // If a typed decoder is registered, decode raw and apply it to the inner
    // MsgFromServer term so nested payload types use the correct constructors.
    let decoded;
    const typedDecoder = getMsgFromServerDecoder();
    if (typedDecoder) {
      // Decode the full payload raw: no registry reconstruction.
      // raw is a plain JS array: ["ok", rawMsgFromServerTerm] or
      // ["error", rawRpcErrorTerm].
      const raw = decode_value_raw(payload);
      if (Array.isArray(raw) && raw[0] === "ok" && raw[1] !== undefined) {
        // Ok branch: apply the typed decoder to the inner MsgFromServer value.
        const typedVariant = typedDecoder(raw[1]);
        decoded = new Ok(typedVariant);
      } else {
        // Error branch or unexpected shape: fall back to registry decode.
        decoded = decode_value(payload);
      }
    } else {
      decoded = decode_value(payload);
    }
    const entry = responseCallbacks.shift();
    if (entry) {
      if (entry.timer) clearTimeout(entry.timer);
      entry.callback(decoded);
    }
  });

  ws.addEventListener("close", () => {
    ws = null;
    clearAllPending("WebSocket connection closed");
  });

  ws.addEventListener("error", () => {
    if (ws) {
      ws.close();
    }
  });
}

// Send a message and queue a callback for the server's response.
// Responses are matched to sends in FIFO order. Each request has a
// 30-second timeout - if no response arrives, the callback receives
// an InternalError so the UI doesn't hang indefinitely.
export function send(url, module, msg, callback) {
  ensureSocket(url);
  const payload = encode_call(module, msg);
  const timer = setTimeout(() => {
    // Remove from whichever queue this entry is in
    const pendingIdx = pendingSends.findIndex(e => e.callback === callback);
    if (pendingIdx !== -1) {
      pendingSends.splice(pendingIdx, 1);
    }
    const responseIdx = responseCallbacks.findIndex(e => e.callback === callback);
    if (responseIdx !== -1) {
      responseCallbacks.splice(responseIdx, 1);
    }
    callback(makeConnectionError("Request timed out"));
  }, REQUEST_TIMEOUT_MS);

  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(payload);
    responseCallbacks.push({ callback, timer });
  } else {
    pendingSends.push({ payload, callback, timer });
  }
}

// Register a push handler for a specific module. When the server
// sends a push frame tagged with this module path, the callback
// is invoked with the decoded value.
export function registerPushHandler(module, callback) {
  pushHandlers.set(module, callback);
}

// Encode a call envelope: {module_name, msg} as ETF binary.
// Symmetric with the server-side wire.encode_call.
export function encode_call(module, msg) {
  const encoder = new ETFEncoder();
  encoder.writeUint8(131); // ETF version byte
  // Envelope: {<<"module_name">>, msg_value}
  encoder.writeUint8(104); // SMALL_TUPLE_EXT
  encoder.writeUint8(2);   // arity 2
  encoder.encodeBinary(module);
  encoder.encodeTerm(msg);
  return encoder.result();
}
