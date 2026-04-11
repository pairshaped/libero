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

export function setListCtors(empty, nonEmpty) {
  Empty = empty;
  NonEmpty = nonEmpty;
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

function toJsPrimitive(v) {
  if (Array.isArray(v)) return v.map(toJsPrimitive);
  if (v && typeof v === "object" && v.head !== undefined) {
    return gleamListToArray(v).map(toJsPrimitive);
  }
  return v;
}

// ---------- Auto-wire Gleam prelude + Record ----------

try {
  const prelude = await import("../gleam.mjs");
  if (prelude.Empty && prelude.NonEmpty) {
    setListCtors(prelude.Empty, prelude.NonEmpty);
  }
  if (prelude.Ok) registerConstructor("ok", prelude.Ok);
  if (prelude.Error) registerConstructor("error", prelude.Error);
} catch (_) {
  // Standalone mode (Node REPL) — prelude unavailable.
}

try {
  const recordMod = await import("../../shared/shared/record.mjs");
  if (recordMod.Record) registerConstructor("record", recordMod.Record);
  // App-specific error types used by @rpc functions
  if (recordMod.DuplicateEmail)
    registerConstructor("duplicate_email", recordMod.DuplicateEmail);
  if (recordMod.DatabaseError)
    registerConstructor("database_error", recordMod.DatabaseError);
  if (recordMod.NotFound) registerConstructor("not_found", recordMod.NotFound);
  if (recordMod.DuplicateEmailOnUpdate)
    registerConstructor(
      "duplicate_email_on_update",
      recordMod.DuplicateEmailOnUpdate,
    );
  if (recordMod.UpdateDatabaseError)
    registerConstructor("update_database_error", recordMod.UpdateDatabaseError);
} catch (_) {
  // Standalone mode — shared.Record unavailable.
}

// Libero error envelope types — every RPC response can include these
// framework error variants on top of the app's own error type.
try {
  const errorMod = await import("../../shared/shared/libero/error.mjs");
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
