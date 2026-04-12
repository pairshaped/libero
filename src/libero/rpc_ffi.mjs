// JSON wire format for cosmic_gleam RPC.
//
// Wire shape (mirrors server/src/server/wire_json.gleam):
//   - Primitives → JSON primitives
//   - Gleam List(a) → JSON array
//   - Gleam custom type `Record(1, "alice", ...)` → {"@": "record", "v": [1, "alice", ...]}
//
// The `rebuild` function walks the parsed JSON tree and reconstructs
// custom type instances using a small constructor registry. Gleam lists
// are rebuilt as linked lists so `gleam/list` operations work on them.

// ---------- Identity helper (for Gleam FFI) ----------

export function identity(x) {
  return x;
}

// ---------- Constructor registry ----------

const registry = new Map();

export function registerConstructor(atomName, ctor) {
  registry.set(atomName, ctor);
}

// Gleam list constructors — set at module load time from the prelude.
let Empty = null;
let NonEmpty = null;
// Gleam CustomType base class — set from the prelude so the encoder
// can detect custom type instances and serialize them as tagged objects.
let GleamCustomType = null;

export function setListCtors(empty, nonEmpty) {
  Empty = empty;
  NonEmpty = nonEmpty;
}

// gleam/dict's `from_list` — set at module load time. The encoder on
// the server side emits Dict values as `{"@": "dict", "v": [[k, v], ...]}`
// so the client rebuild function can distinguish a real Dict from an
// incidentally-shaped tuple array. Rebuild calls this to turn the
// decoded list-of-pairs back into a Gleam Dict instance.
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

// ---------- Decoder ----------

export function decode(text) {
  return rebuild(JSON.parse(text));
}

function rebuild(value) {
  // Tagged custom type: {"@": "ctor_name", "v": [...fields]}
  if (
    value !== null
    && typeof value === "object"
    && !Array.isArray(value)
    && "@" in value
  ) {
    const tag = value["@"];
    // "dict" is a reserved framework tag for Gleam Dict values. Rather
    // than going through the constructor registry, we rebuild each
    // [k, v] pair and hand the resulting array to gleam/dict.from_list.
    if (tag === "dict") {
      // Each element of `v` is a 2-element JSON array [k, v]. Rebuild
      // each side first so keys and values can themselves be custom
      // types, nested dicts, lists, etc. Gleam tuples compile to plain
      // JS arrays, so the rebuilt pair is exactly the shape
      // `gleam/dict.from_list` expects as an element of its List input.
      const pairs = (value.v || []).map((pair) => [
        rebuild(pair[0]),
        rebuild(pair[1]),
      ]);
      if (dictFromList === null) {
        // Standalone mode (Node REPL / tests) — fall back to a plain
        // JS Map. Production consumers auto-wire setDictFromList from
        // the gleam_stdlib dict module below.
        return new Map(pairs);
      }
      return dictFromList(arrayToGleamList(pairs));
    }
    const fields = (value.v || []).map(rebuild);
    const Ctor = registry.get(tag);
    if (!Ctor) throw new Error(`rebuild: unknown constructor "${tag}"`);
    return new Ctor(...fields);
  }

  // JSON array → Gleam list
  if (Array.isArray(value)) {
    return arrayToGleamList(value.map(rebuild));
  }

  // Primitives (string, number, boolean, null) pass through unchanged.
  return value;
}

// ---------- Encoder ----------
//
// `args` from the Gleam side can be any of:
//   - `Nil` → JS `undefined` (zero-arg functions like records.list)
//   - a scalar (Int, String, Bool) → JS primitive (single-arg functions like
//     records.delete(id))
//   - a tuple `#(a, b, c)` → JS array (multi-arg functions like records.save)
//   - a Gleam list → linked list object (rare, but supported)
//
// `normalizeArgs` flattens all of those into a plain JS array of primitives
// that JSON.stringify can serialize directly.

export function encode(name, args) {
  return JSON.stringify({ fn: name, args: normalizeArgs(args) });
}

function normalizeArgs(args) {
  // Nil in Gleam compiles to undefined on JS.
  if (args === undefined) return [];
  // JS array = Gleam tuple — already positional, just walk.
  if (Array.isArray(args)) return args.map(toJsPrimitive);
  // Gleam linked list — flatten and walk.
  if (args && typeof args === "object" && args.head !== undefined) {
    return gleamListToArray(args).map(toJsPrimitive);
  }
  // Single scalar arg — wrap in a one-element array.
  return [toJsPrimitive(args)];
}

function snakeCase(name) {
  return name
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .replace(/([A-Z])([A-Z][a-z])/g, "$1_$2")
    .toLowerCase();
}

function toJsPrimitive(v) {
  // null / undefined / primitives — pass through
  if (v === null || v === undefined) return v;
  if (typeof v !== "object" && typeof v !== "function") return v;
  // JS array = Gleam tuple — recurse into elements
  if (Array.isArray(v)) return v.map(toJsPrimitive);
  // Gleam linked list — flatten and recurse. NonEmpty has .head,
  // Empty is detected via the stored constructor reference.
  if (v.head !== undefined) {
    return gleamListToArray(v).map(toJsPrimitive);
  }
  if (Empty !== null && v instanceof Empty) {
    return [];
  }
  // Gleam Dict (JS Map) — encode as tagged dict with [k, v] pairs
  if (v instanceof Map) {
    const pairs = [];
    v.forEach((val, key) => {
      pairs.push([toJsPrimitive(key), toJsPrimitive(val)]);
    });
    return { "@": "dict", v: pairs };
  }
  // Gleam custom type instance — encode as tagged object
  if (GleamCustomType && v instanceof GleamCustomType) {
    const ctorName = snakeCase(v.constructor.name);
    const keys = Object.keys(v);
    // 0-arity constructors (like None) are tagged objects with empty
    // field arrays. Don't special-case None as null — the server's
    // rebuild function converts {"@":"none","v":[]} back to the atom
    // `nil` (Gleam's None representation on BEAM).
    if (keys.length === 0) {
      return { "@": ctorName, v: [] };
    }
    const fields = keys.map((k) => toJsPrimitive(v[k]));
    return { "@": ctorName, v: fields };
  }
  // Unknown object — return as-is (JSON.stringify will handle it)
  return v;
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
  // Standalone mode (Node REPL) — prelude unavailable.
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
  // Standalone mode — libero error unavailable.
}

try {
  const optionMod = await import("../../gleam_stdlib/gleam/option.mjs");
  if (optionMod.Some) registerConstructor("some", optionMod.Some);
  if (optionMod.None) registerConstructor("none", optionMod.None);
} catch (_) {
  // Standalone mode — gleam_stdlib unavailable.
}

try {
  const dictMod = await import("../../gleam_stdlib/gleam/dict.mjs");
  if (dictMod.from_list) setDictFromList(dictMod.from_list);
} catch (_) {
  // Standalone mode — gleam_stdlib unavailable. rebuild will fall
  // back to `new Map(...)` for dict values, which is fine for tests
  // but won't produce a genuine Gleam Dict instance.
}

// ---------- WebSocket + call queue ----------
//
// Every `call` receives the WebSocket URL as its first argument. On the
// first call, the socket is opened lazily. Subsequent calls reuse the
// existing connection (the URL is a compile-time const from Gleam's
// rpc_config module, so it doesn't change across calls). Calls issued
// before the socket's open event are queued and flushed once it opens.

let ws = null;
let callbackQueue = [];
let pendingSends = [];

function ensureSocket(url) {
  if (ws !== null) return;
  ws = new WebSocket(url);
  ws.addEventListener("open", () => {
    for (const payload of pendingSends) ws.send(payload);
    pendingSends = [];
  });
  ws.addEventListener("message", (event) => {
    const text = typeof event.data === "string"
      ? event.data
      : new TextDecoder().decode(event.data);
    const value = decode(text);
    const cb = callbackQueue.shift();
    if (cb) cb(value);
  });
}

export function call(url, name, args, onResponse) {
  ensureSocket(url);
  const payload = encode(name, args);
  callbackQueue.push(onResponse);
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(payload);
  } else {
    pendingSends.push(payload);
  }
}
