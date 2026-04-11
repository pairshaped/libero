//// Reflective JSON wire format for Libero RPC.
////
//// The encoder walks any Gleam value via Erlang runtime introspection and
//// emits a JSON tree that preserves enough structure to rebuild Gleam
//// custom types on the client via a constructor registry.
////
//// **Wire shape:**
//// - Primitives (Int, Float, Bool, String) → JSON primitives
//// - `Nil` / `None` → JSON `null`
//// - Gleam `List(a)` → JSON array of encoded elements
//// - Plain tuple `#(a, b, c)` → JSON array of encoded elements (no tag)
//// - Gleam custom type `Record(1, "alice", ...)` → `{"@": "record", "v": [1, "alice", ...]}`
////
//// The distinction between "Gleam custom type" and "plain tuple" is made at
//// encode time: if the first element of a tuple is a non-boolean atom, the
//// tuple is treated as a custom type (where the atom is the constructor
//// name). Otherwise it's serialized as a plain array. This mirrors Gleam's
//// BEAM compilation: `Record(...)` becomes `{record, ...}` with the lowercase
//// atom in position 0.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/result

// ---------- Encoder ----------

pub fn encode(value: a) -> String {
  json.to_string(walk(coerce(value)))
}

/// Walk any Erlang term and build a `gleam/json.Json` tree.
fn walk(value: Dynamic) -> Json {
  // Order matters: `is_boolean` must come before `is_atom` because
  // `true`/`false` are atoms in Erlang but should become JSON booleans.
  let is_bool_v = is_boolean(value)
  let is_atom_v = is_atom(value)
  let is_int_v = is_integer(value)
  let is_float_v = is_float(value)
  let is_binary_v = is_binary(value)
  let is_list_v = is_list(value)
  let is_tuple_v = is_tuple(value)

  case
    is_bool_v,
    is_atom_v,
    is_int_v,
    is_float_v,
    is_binary_v,
    is_list_v,
    is_tuple_v
  {
    True, _, _, _, _, _, _ -> json.bool(to_bool(value))
    _, True, _, _, _, _, _ -> atom_to_json(atom_name(value))
    _, _, True, _, _, _, _ -> json.int(to_int(value))
    _, _, _, True, _, _, _ -> json.float(to_float(value))
    _, _, _, _, True, _, _ -> json.string(to_string(value))
    _, _, _, _, _, True, _ ->
      json.preprocessed_array(list.map(to_list(value), walk))
    _, _, _, _, _, _, True -> tuple_to_json(tuple_to_list(value))
    _, _, _, _, _, _, _ -> panic as "wire_json: unsupported term in encoder"
  }
}

fn atom_to_json(name: String) -> Json {
  case name {
    "nil" -> json.null()
    // Bare 0-arity atoms (like `None`) become a tagged object with no fields.
    _ ->
      json.object([
        #("@", json.string(name)),
        #("v", json.preprocessed_array([])),
      ])
  }
}

fn tuple_to_json(elements: List(Dynamic)) -> Json {
  case elements {
    [] -> json.preprocessed_array([])
    [first, ..rest] -> {
      // A Gleam custom type has a non-boolean atom in position 0.
      case is_atom(first) && !is_boolean(first) {
        True ->
          json.object([
            #("@", json.string(atom_name(first))),
            #("v", json.preprocessed_array(list.map(rest, walk))),
          ])
        False -> json.preprocessed_array(list.map(elements, walk))
      }
    }
  }
}

// ---------- Decoder (incoming call envelope) ----------

pub type DecodeError {
  DecodeError(message: String, cause: json.DecodeError)
}

/// Parse `{"fn": "records.save", "args": [...]}` from text.
/// Args come back as a `List(Dynamic)`. The dispatch table coerces each
/// one to its expected type via `gleam_stdlib:identity`.
pub fn decode_call(
  text: String,
) -> Result(#(String, List(Dynamic)), DecodeError) {
  let decoder = {
    use fn_name <- decode.field("fn", decode.string)
    use args <- decode.field("args", decode.list(decode.dynamic))
    decode.success(#(fn_name, args))
  }
  json.parse(text, decoder)
  |> result.map_error(fn(err) {
    DecodeError(message: "invalid call envelope", cause: err)
  })
}

// ---------- Erlang FFI ----------

@external(erlang, "erlang", "is_boolean")
fn is_boolean(value: Dynamic) -> Bool

@external(erlang, "erlang", "is_atom")
fn is_atom(value: Dynamic) -> Bool

@external(erlang, "erlang", "is_integer")
fn is_integer(value: Dynamic) -> Bool

@external(erlang, "erlang", "is_float")
fn is_float(value: Dynamic) -> Bool

@external(erlang, "erlang", "is_binary")
fn is_binary(value: Dynamic) -> Bool

@external(erlang, "erlang", "is_list")
fn is_list(value: Dynamic) -> Bool

@external(erlang, "erlang", "is_tuple")
fn is_tuple(value: Dynamic) -> Bool

@external(erlang, "erlang", "atom_to_binary")
fn atom_name(value: Dynamic) -> String

@external(erlang, "erlang", "tuple_to_list")
fn tuple_to_list(value: Dynamic) -> List(Dynamic)

// Identity-based unsafe coercions. The `is_*` checks above have already
// confirmed the runtime shape, we just need to tell Gleam's type system.

@external(erlang, "gleam_stdlib", "identity")
fn coerce(value: a) -> Dynamic

@external(erlang, "gleam_stdlib", "identity")
fn to_bool(value: Dynamic) -> Bool

@external(erlang, "gleam_stdlib", "identity")
fn to_int(value: Dynamic) -> Int

@external(erlang, "gleam_stdlib", "identity")
fn to_float(value: Dynamic) -> Float

@external(erlang, "gleam_stdlib", "identity")
fn to_string(value: Dynamic) -> String

@external(erlang, "gleam_stdlib", "identity")
fn to_list(value: Dynamic) -> List(Dynamic)
