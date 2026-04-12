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
//// - Gleam `Dict(k, v)` → `{"@": "dict", "v": [[k1, v1], [k2, v2], ...]}`
////
//// The distinction between "Gleam custom type" and "plain tuple" is made at
//// encode time: if the first element of a tuple is a non-boolean atom, the
//// tuple is treated as a custom type (where the atom is the constructor
//// name). Otherwise it's serialized as a plain array. This mirrors Gleam's
//// BEAM compilation: `Record(...)` becomes `{record, ...}` with the lowercase
//// atom in position 0.
////
//// `Dict(k, v)` is an Erlang map at runtime. The encoder flattens the map
//// to a list of [key, value] pairs (sorted by key for deterministic wire
//// output) and wraps it in the "dict" tag so the client's rebuild function
//// can distinguish a real dict from an incidentally-shaped tuple array.

import gleam/dict as map
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
  let is_map_v = is_map(value)

  case
    is_bool_v,
    is_atom_v,
    is_int_v,
    is_float_v,
    is_binary_v,
    is_list_v,
    is_tuple_v,
    is_map_v
  {
    True, _, _, _, _, _, _, _ -> json.bool(to_bool(value))
    _, True, _, _, _, _, _, _ -> atom_to_json(atom_name(value))
    _, _, True, _, _, _, _, _ -> json.int(to_int(value))
    _, _, _, True, _, _, _, _ -> json.float(to_float(value))
    _, _, _, _, True, _, _, _ -> json.string(to_string(value))
    _, _, _, _, _, True, _, _ ->
      json.preprocessed_array(list.map(to_list(value), walk))
    _, _, _, _, _, _, True, _ -> tuple_to_json(tuple_to_list(value))
    _, _, _, _, _, _, _, True -> dict_to_json(map_to_list(value))
    _, _, _, _, _, _, _, _ -> panic as "wire_json: unsupported term in encoder"
  }
}

/// Encode a Gleam Dict as `{"@": "dict", "v": [[k1, v1], [k2, v2], ...]}`.
/// The pairs arrive from Erlang's `maps:to_list/1` as 2-element tuples; we
/// walk each to recursively encode keys and values, then emit a tuple
/// element for each pair. The "dict" tag lets the client rebuild the
/// Gleam Dict via `dict.from_list` instead of mistaking it for a plain
/// list of tuples.
fn dict_to_json(pairs: List(#(Dynamic, Dynamic))) -> Json {
  let encoded_pairs =
    list.map(pairs, fn(pair) {
      let #(k, v) = pair
      json.preprocessed_array([walk(k), walk(v)])
    })
  json.object([
    #("@", json.string("dict")),
    #("v", json.preprocessed_array(encoded_pairs)),
  ])
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
/// Each arg is run through `rebuild` to convert tagged JSON objects
/// (`{"@": "tag", "v": [...]}`) back into Erlang tuples that match the
/// Gleam custom type representation (`{tag, field1, field2, ...}`).
/// This mirrors the client-side `rebuild` in rpc_ffi.mjs, letting
/// consumers pass custom types (records, enums, Option values) as
/// @rpc arguments, not just primitives.
pub fn decode_call(
  text: String,
) -> Result(#(String, List(Dynamic)), DecodeError) {
  let decoder = {
    use fn_name <- decode.field("fn", decode.string)
    use args <- decode.field("args", decode.list(decode.dynamic))
    decode.success(#(fn_name, list.map(args, rebuild)))
  }
  json.parse(text, decoder)
  |> result.map_error(fn(err) {
    DecodeError(message: "invalid call envelope", cause: err)
  })
}

/// Reconstruct a JSON-parsed Dynamic value into its Gleam-native shape.
///
/// - `{"@": "tag", "v": [f1, f2, ...]}` → Erlang tuple `{tag, rebuild(f1), ...}`
///   which is how Gleam custom types are represented on BEAM.
/// - `{"@": "dict", "v": [[k1, v1], ...]}` → Erlang map `%{k1 => v1, ...}`.
/// - JSON array → Gleam List (via `list.map` which is already a Gleam list)
/// - JSON null → Already decoded as `Nil` by gleam_json.
/// - Primitives → Pass through unchanged.
///
/// This is the server-side counterpart of rpc_ffi.mjs's `rebuild()`.
fn rebuild(value: Dynamic) -> Dynamic {
  // JSON null → Gleam Nil (Erlang atom `nil`). gleam_json decodes
  // null as the atom `null`, but Gleam's Nil/None is the atom `nil`.
  // Translate before anything else.
  case is_null(value) {
    True -> coerce(Nil)
    False -> rebuild_non_null(value)
  }
}

fn rebuild_non_null(value: Dynamic) -> Dynamic {
  // Try tagged object first: {"@": "...", "v": [...]}
  let tag_decoder = {
    use tag <- decode.field("@", decode.string)
    use fields <- decode.field("v", decode.list(decode.dynamic))
    decode.success(#(tag, fields))
  }
  case decode.run(value, tag_decoder) {
    Ok(#("dict", pairs)) -> {
      // Reconstruct as Erlang map (Gleam Dict).
      let map_entries =
        list.filter_map(pairs, fn(pair) {
          case decode.run(pair, decode.list(decode.dynamic)) {
            Ok([k, v]) -> Ok(#(rebuild(k), rebuild(v)))
            _ -> Error(Nil)
          }
        })
      coerce(map.from_list(map_entries))
    }
    Ok(#(tag, fields)) -> {
      // Reconstruct as Erlang tuple: {atom, field1, field2, ...}
      let atom = binary_to_atom(tag)
      let rebuilt_fields = list.map(fields, rebuild)
      list_to_tuple([atom, ..rebuilt_fields])
    }
    Error(_) -> {
      // Not a tagged object — check if it's a list (recurse into elements)
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(items) -> coerce(list.map(items, rebuild))
        Error(_) -> value
      }
    }
  }
}

/// binary_to_atom is safe here (vs binary_to_existing_atom) because the
/// atom strings come from our own wire protocol, not arbitrary user input.
/// At decode time the target module may not be loaded yet, so the atom may
/// not exist — binary_to_atom creates it. When the module loads later it
/// reuses the same atom.
@external(erlang, "erlang", "binary_to_atom")
fn binary_to_atom(name: String) -> Dynamic

@external(erlang, "libero_ffi", "is_null")
fn is_null(value: Dynamic) -> Bool

@external(erlang, "erlang", "list_to_tuple")
fn list_to_tuple(elements: List(Dynamic)) -> Dynamic

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

@external(erlang, "erlang", "is_map")
fn is_map(value: Dynamic) -> Bool

@external(erlang, "erlang", "atom_to_binary")
fn atom_name(value: Dynamic) -> String

@external(erlang, "erlang", "tuple_to_list")
fn tuple_to_list(value: Dynamic) -> List(Dynamic)

@external(erlang, "maps", "to_list")
fn map_to_list(value: Dynamic) -> List(#(Dynamic, Dynamic))

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
