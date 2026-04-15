// ETF wire format for libero RPC.
//
// Wire shape: Erlang External Term Format (ETF), subset used by Gleam.
// WebSocket uses binary frames (ArrayBuffer).
//
// The decoder reconstructs custom type instances using a constructor
// registry. Gleam lists are rebuilt as linked lists so `gleam/list`
// operations work on them.

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

// ---------- Constructor registry ----------

const registry = new Map();

export function registerConstructor(atomName, ctor) {
  registry.set(atomName, ctor);
}

// Gleam list constructors - set at module load time from the prelude.
let Empty = null;
let NonEmpty = null;
// Gleam CustomType base class - set from the prelude so the encoder
// can detect custom type instances and serialize them as tagged tuples.
let GleamCustomType = null;

export function setListCtors(empty, nonEmpty) {
  Empty = empty;
  NonEmpty = nonEmpty;
}

// gleam/dict's `from_list` - set at module load time. The server
// encodes Dict values as MAP_EXT. The decoder converts them back to
// a Gleam Dict instance via from_list.
let dictFromList = null;

export function setDictFromList(fn) {
  dictFromList = fn;
}

function arrayToGleamList(arr) {
  if (Empty === null || NonEmpty === null) {
    return arr; // standalone mode (Node REPL)
  }
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
  constructor(input) {
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
    // 0-arity constructor
    const Ctor = registry.get(name);
    if (Ctor) return new Ctor();
    // Unknown atom - return as string (shouldn't normally happen)
    return name;
  }

  decodeTuple(arity) {
    if (arity === 0) return [];

    // Peek at first element to check for atom tag (constructor)
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

      // Look up constructor in registry
      const Ctor = registry.get(atomName);
      if (Ctor) {
        const fields = [];
        for (let i = 1; i < arity; i++) {
          fields.push(this.decodeTerm());
        }
        return new Ctor(...fields);
      }

      // Unknown atom-tagged tuple - decode remaining and return array
      // Use the atom name as first element (string representation)
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
    if (dictFromList === null) {
      // Standalone mode - fall back to JS Map
      return new Map(pairs);
    }
    return dictFromList(arrayToGleamList(pairs));
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
    if (GleamCustomType && value instanceof GleamCustomType) {
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
// constructors must have been registered via `register_all()` at
// boot for the decoder to rebuild them correctly.
export function decode_value(buffer) {
  const decoder = new ETFDecoder(buffer);
  return decoder.decode();
}

// Safe variant of decode_value that returns a Result instead of throwing.
// Used by the public `libero.wire.decode_safe` function.
//
// NOTE: This function looks up Ok/Error/DecodeError constructors from the
// registry, falling back to plain objects if they aren't registered yet.
// Ok and Error are registered via top-level `await` above (guaranteed
// before any consumer code runs). DecodeError is registered via a
// fire-and-forget dynamic import to avoid a circular dependency with
// wire.mjs - it resolves after module init but before any client boot
// code calls decode_safe. If this function is ever called during module
// initialization (before register_all), the plain-object fallback won't
// match Gleam pattern matching. In practice this can't happen because
// decode_safe is only reachable after the consumer calls register_all().
export function decode_safe(buffer) {
  try {
    const decoder = new ETFDecoder(buffer);
    const value = decoder.decode();
    const okCtor = registry.get("ok");
    if (okCtor) return new okCtor(value);
    return { type: "Ok", 0: value };
  } catch (e) {
    const msg = e && e.message ? e.message : String(e);
    const errorCtor = registry.get("error");
    const decodeCtor = registry.get("decode_error");
    if (errorCtor && decodeCtor) return new errorCtor(new decodeCtor(msg));
    return { type: "Error", 0: { type: "DecodeError", 0: msg } };
  }
}

// ---------- Auto-wire Gleam prelude + libero framework types ----------
//
// Everything registered here is UNIVERSAL across all libero consumers:
// - Prelude constructors (Ok, Error) that wrap every RPC response.
// - Libero framework error variants (AppError, MalformedRequest,
//   UnknownFunction, InternalError) that every RPC can surface through
//   the error envelope.
//
// Consumer application types (records, unions, options on fields) are
// NOT registered here. Those are discovered by libero's generator and
// emitted into a per-namespace rpc_register.mjs in the consumer's
// generated output directory. The consumer calls register_all() from
// that file once at boot before the first RPC.

try {
  const prelude = await import("../gleam.mjs");
  if (prelude.Empty && prelude.NonEmpty) {
    setListCtors(prelude.Empty, prelude.NonEmpty);
  }
  if (prelude.Ok) registerConstructor("ok", prelude.Ok);
  if (prelude.Error) registerConstructor("error", prelude.Error);
  if (prelude.CustomType) GleamCustomType = prelude.CustomType;
} catch (_) {
  // Standalone mode (Node REPL) - prelude unavailable.
}

try {
  const errorMod = await import("./error.mjs");
  if (errorMod.AppError) registerConstructor("app_error", errorMod.AppError);
  if (errorMod.MalformedRequest)
    registerConstructor("malformed_request", errorMod.MalformedRequest);
  if (errorMod.UnknownFunction)
    registerConstructor("unknown_function", errorMod.UnknownFunction);
  if (errorMod.InternalError)
    registerConstructor("internal_error", errorMod.InternalError);
} catch (_) {
  // Standalone mode - libero error unavailable.
}

// wire.mjs statically imports decode_safe from this module, so an
// `await import("./wire.mjs")` here would deadlock: this module's
// top-level await would block wire.mjs from loading, and wire.mjs
// would block this module's decode_safe binding from resolving. Fire
// the dynamic import without awaiting so the DecodeError constructor
// registers after both modules have settled. decode_safe is only
// called after the client boots, well after this microtask resolves.
import("./wire.mjs")
  .then((wireMod) => {
    if (wireMod.DecodeError)
      registerConstructor("decode_error", wireMod.DecodeError);
  })
  .catch(() => {
    // Standalone mode - libero wire unavailable.
  });

try {
  const optionMod = await import("../../gleam_stdlib/gleam/option.mjs");
  if (optionMod.Some) registerConstructor("some", optionMod.Some);
  if (optionMod.None) registerConstructor("none", optionMod.None);
} catch (_) {
  // Standalone mode - gleam_stdlib unavailable.
}

try {
  const dictMod = await import("../../gleam_stdlib/gleam/dict.mjs");
  if (dictMod.from_list) setDictFromList(dictMod.from_list);
} catch (_) {
  // Standalone mode - gleam_stdlib unavailable. decode will fall
  // back to `new Map(...)` for dict values, which is fine for tests
  // but won't produce a genuine Gleam Dict instance.
}

// ---------- WebSocket ----------
//
// `send` opens the WebSocket lazily on first call and caches the
// connection. The URL is a compile-time constant from Gleam's
// rpc_config module, so it doesn't change across calls. Sends issued
// before the socket's open event are queued and flushed once it opens.
//
// NOTE: Responses are matched to requests by FIFO order - no request
// IDs or correlation tokens. This works because the server processes
// requests sequentially over a single WebSocket and never sends
// unsolicited pushes. If the architecture changes to support
// concurrent request processing or server-initiated pushes, this
// must be replaced with a correlation-based scheme (e.g. request IDs).

let ws = null;
let pendingSends = [];    // [{payload, callback, timer}]
let responseCallbacks = []; // [{callback, timer}]
const REQUEST_TIMEOUT_MS = 30_000;

// Build a connection-error value using registered constructors.
// Falls back to a plain object if constructors aren't registered yet.
function makeConnectionError(message) {
  const errCtor = registry.get("error");
  const intErrCtor = registry.get("internal_error");
  if (errCtor && intErrCtor) {
    return new errCtor(new intErrCtor("", message));
  }
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
    const decoded = decode_value(new Uint8Array(event.data));
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
