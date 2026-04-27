// Static library of primitive + combinator decoders used by generated
// rpc_decoders_ffi.mjs files. This module ships with libero; it is not
// generated.
//
// Gleam stdlib types (Ok, Error, Some, None, Empty, NonEmpty) are
// injected via setters at module load time - same pattern as rpc_ffi.mjs.
// The generated register file calls these setters before any RPC arrives.

// --- Gleam stdlib types (set via setters, no direct imports) ---

let _Ok = null;
let _ResultError = null;
let _Some = null;
let _None = null;
let _Empty = null;
let _NonEmpty = null;

export function setResultCtors(ok, error) {
  _Ok = ok;
  _ResultError = error;
}

export function setOptionCtors(some, none) {
  _Some = some;
  _None = none;
}

export function setListCtors(empty, nonEmpty) {
  _Empty = empty;
  _NonEmpty = nonEmpty;
}

let _dictFromList = null;

export function setDictFromList(fn) {
  _dictFromList = fn;
}

// --- DecodeError ---

export class DecodeError extends Error {
  constructor(message) {
    super(message);
    this.name = "DecodeError";
  }
}

// --- Primitive decoders ---

const textDecoder = new TextDecoder();

export const decode_int = (term) => {
  // ETF decoder produces BigInt for integers exceeding Number.MAX_SAFE_INTEGER.
  // Coerce to Number since Gleam's JS target uses Number for Int.
  if (typeof term === "bigint") {
    if (term < Number.MIN_SAFE_INTEGER || term > Number.MAX_SAFE_INTEGER) {
      throw new DecodeError(
        "expected Int within safe integer range, got BigInt " + String(term),
      );
    }
    return Number(term);
  }
  if (typeof term !== "number") {
    throw new DecodeError("expected Int, got " + typeof term);
  }
  return term;
};

export const decode_float = (term) => {
  if (typeof term !== "number") {
    throw new DecodeError("expected Float, got " + typeof term);
  }
  return term;
};

export const decode_string = (term) => {
  if (term && term.__liberoRawBinary === true && term.rawBuffer instanceof Uint8Array) {
    return textDecoder.decode(term.rawBuffer);
  }
  if (typeof term !== "string") {
    throw new DecodeError("expected String, got " + typeof term);
  }
  return term;
};

export const decode_bool = (term) => {
  // Accepts both native booleans and strings "true"/"false" by design:
  // ETF atoms decode to strings in raw mode, so the atom `true` arrives
  // as the string "true". The typed decoder knows the expected type, so
  // this ambiguity with Gleam String("true") is harmless in practice.
  if (term === true || term === "true") return true;
  if (term === false || term === "false") return false;
  throw new DecodeError("expected Bool, got " + String(term));
};

export const decode_bit_array = (term) => {
  // libero's ETF decoder produces a BitArray-compatible value (has rawBuffer).
  // Validate the shape to catch type mismatches early.
  if (term && term.rawBuffer instanceof Uint8Array) return term;
  // Also accept raw Uint8Array for interop convenience.
  if (term instanceof Uint8Array) return term;
  throw new DecodeError("expected BitArray, got " + typeof term);
};

export const decode_nil = (term) => {
  // Gleam `Nil` compiles to `undefined` on JS. Wire value is an empty
  // tuple on Erlang; the raw decoder hands us back either `undefined` or
  // `[]` (empty tuple) depending on context. Either way, Nil has no
  // runtime payload; validate then return undefined.
  if (term === undefined || term === null) return undefined;
  if (Array.isArray(term) && term.length === 0) return undefined;
  throw new DecodeError("expected Nil, got " + typeof term);
};

// --- Generic combinators ---

export function decode_list_of(elementDecoder, term) {
  // libero's ETF decoder produces a native JS array for Gleam lists.
  if (!Array.isArray(term)) {
    throw new DecodeError("expected List, got " + typeof term);
  }
  // Match decode_dict_of: throw if setListCtors hasn't run, since a
  // silent JS-array fallback would crash deep inside the consumer's
  // view code with a less actionable error than this one.
  if (_Empty === null || _NonEmpty === null) {
    throw new DecodeError("setListCtors not called");
  }
  const decoded = term.map(elementDecoder);
  let list = new _Empty();
  for (let i = decoded.length - 1; i >= 0; i--) {
    list = new _NonEmpty(decoded[i], list);
  }
  return list;
}

export function decode_option_of(innerDecoder, term) {
  if (term === "none") {
    if (_None === null) throw new DecodeError("setOptionCtors not called");
    return new _None();
  }
  if (Array.isArray(term) && term[0] === "some") {
    if (_Some === null) throw new DecodeError("setOptionCtors not called");
    return new _Some(innerDecoder(term[1]));
  }
  throw new DecodeError("expected Option, got " + String(term));
}

export function decode_result_of(okDecoder, errDecoder, term) {
  if (Array.isArray(term) && term[0] === "ok") {
    if (_Ok === null) throw new DecodeError("setResultCtors not called");
    return new _Ok(okDecoder(term[1]));
  }
  if (Array.isArray(term) && term[0] === "error") {
    if (_ResultError === null) throw new DecodeError("setResultCtors not called");
    return new _ResultError(errDecoder(term[1]));
  }
  throw new DecodeError("expected Result, got " + String(term));
}

export function decode_dict_of(keyDecoder, valueDecoder, term) {
  // In raw mode, Dict arrives as an array of [k, v] pairs.
  if (!Array.isArray(term)) {
    throw new DecodeError("expected Dict pairs array, got " + typeof term);
  }
  if (_dictFromList === null) throw new DecodeError("setDictFromList not called");
  if (_Empty === null || _NonEmpty === null)
    throw new DecodeError("setListCtors not called");
  const decoded = term.map(([k, v]) => [keyDecoder(k), valueDecoder(v)]);
  // Build a Gleam linked list of 2-tuples and hand it to dict.from_list.
  let list = new _Empty();
  for (let i = decoded.length - 1; i >= 0; i--) {
    list = new _NonEmpty(decoded[i], list);
  }
  return _dictFromList(list);
}

export function decode_tuple_of(elementDecoders, term) {
  if (!Array.isArray(term) || term.length !== elementDecoders.length) {
    throw new DecodeError(
      "tuple arity mismatch: expected " +
        elementDecoders.length +
        ", got " +
        (Array.isArray(term) ? term.length : typeof term),
    );
  }
  return elementDecoders.map((decoder, i) => decoder(term[i]));
}
