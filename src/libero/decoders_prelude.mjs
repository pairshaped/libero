// Static library of primitive + combinator decoders used by generated
// rpc_decoders_ffi.mjs files. This module ships with libero; it is not
// generated.
//
// Gleam stdlib types (Ok, Error, Some, None, Empty, NonEmpty) are
// injected via setters at module load time - same pattern as rpc_ffi.mjs.
// The generated register file calls these setters before any RPC arrives.

// --- Typed MsgFromServer decoder hook ---
//
// The generated rpc_decoders_ffi.mjs calls setMsgFromServerDecoder at
// module load time. rpc_ffi.mjs calls getMsgFromServerDecoder to check
// whether to use the typed path when decoding incoming push frames.

let _msgFromServerDecoder = null;

export function setMsgFromServerDecoder(fn) {
  _msgFromServerDecoder = fn;
}

export function getMsgFromServerDecoder() {
  return _msgFromServerDecoder;
}

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

export const decode_int = (term) => {
  // ETF decoder produces BigInt for integers exceeding Number.MAX_SAFE_INTEGER.
  // Coerce to Number since Gleam's JS target uses Number for Int.
  if (typeof term === "bigint") return Number(term);
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
  if (typeof term !== "string") {
    throw new DecodeError("expected String, got " + typeof term);
  }
  return term;
};

export const decode_bool = (term) => {
  if (term === true || term === "true") return true;
  if (term === false || term === "false") return false;
  throw new DecodeError("expected Bool, got " + String(term));
};

export const decode_bit_array = (term) => {
  // libero's ETF decoder produces a BitArray-compatible value; pass through.
  return term;
};

export const decode_nil = (_term) => {
  // Gleam `Nil` compiles to `undefined` on JS. Wire value is an empty
  // tuple on Erlang; the raw decoder hands us back either `undefined` or
  // `[]` depending on context. Either way, Nil has no runtime payload.
  return undefined;
};

// --- Generic combinators ---

export function decode_list_of(elementDecoder, term) {
  // libero's ETF decoder produces a native JS array for Gleam lists.
  if (!Array.isArray(term)) {
    throw new DecodeError("expected List, got " + typeof term);
  }
  const decoded = term.map(elementDecoder);
  // Rebuild as a Gleam linked list using injected ctors.
  if (_Empty === null || _NonEmpty === null) {
    // Standalone/test mode - return the JS array directly.
    return decoded;
  }
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
