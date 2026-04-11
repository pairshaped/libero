//// Wire-format round-trip tests for libero/wire.
////
//// The encoder walks any Erlang term reflectively and emits JSON.
//// These tests lock in the wire contract for every shape libero
//// needs to handle — primitives, tuples, custom types, lists, and
//// the Result/Option envelopes the generated stubs rely on.

import gleam/option.{None, Some}
import libero/wire

// ---------- Primitive encoding ----------

pub fn encode_int_test() {
  let assert "42" = wire.encode(42)
}

pub fn encode_negative_int_test() {
  let assert "-7" = wire.encode(-7)
}

pub fn encode_float_test() {
  let assert "3.14" = wire.encode(3.14)
}

pub fn encode_string_test() {
  let assert "\"hello\"" = wire.encode("hello")
}

pub fn encode_string_with_escapes_test() {
  let assert "\"line\\nbreak\"" = wire.encode("line\nbreak")
}

pub fn encode_bool_true_test() {
  let assert "true" = wire.encode(True)
}

pub fn encode_bool_false_test() {
  let assert "false" = wire.encode(False)
}

pub fn encode_nil_test() {
  // Gleam's `Nil` is the Erlang atom `nil`, which the encoder renders
  // as JSON null.
  let assert "null" = wire.encode(Nil)
}

// ---------- Composite encoding ----------

pub fn encode_empty_list_test() {
  let empty: List(Int) = []
  let assert "[]" = wire.encode(empty)
}

pub fn encode_int_list_test() {
  let assert "[1,2,3]" = wire.encode([1, 2, 3])
}

pub fn encode_string_list_test() {
  let assert "[\"a\",\"b\"]" = wire.encode(["a", "b"])
}

pub fn encode_tuple_test() {
  // A plain tuple (not a custom type) is encoded as a JSON array.
  let assert "[1,\"two\"]" = wire.encode(#(1, "two"))
}

pub fn encode_nested_list_test() {
  let assert "[[1,2],[3,4]]" = wire.encode([[1, 2], [3, 4]])
}

// ---------- Custom types (tagged envelopes) ----------

pub fn encode_ok_test() {
  // Gleam's `Ok(42)` becomes a Gleam custom type tuple whose first
  // element is the atom `ok` — the encoder detects custom types and
  // wraps them in a `{"@": ctor, "v": [...]}` object.
  let value: Result(Int, String) = Ok(42)
  let assert "{\"@\":\"ok\",\"v\":[42]}" = wire.encode(value)
}

pub fn encode_error_test() {
  let value: Result(Int, String) = Error("nope")
  let assert "{\"@\":\"error\",\"v\":[\"nope\"]}" = wire.encode(value)
}

pub fn encode_ok_with_list_test() {
  let value: Result(List(Int), String) = Ok([1, 2, 3])
  let assert "{\"@\":\"ok\",\"v\":[[1,2,3]]}" = wire.encode(value)
}

pub fn encode_none_test() {
  // `None` is a zero-arity atom — tagged object with empty values.
  let value: option.Option(Int) = None
  let assert "{\"@\":\"none\",\"v\":[]}" = wire.encode(value)
}

pub fn encode_some_test() {
  let value: option.Option(Int) = Some(7)
  let assert "{\"@\":\"some\",\"v\":[7]}" = wire.encode(value)
}

// ---------- Call envelope decoding ----------

pub fn decode_call_empty_args_test() {
  let assert Ok(#("records.list", args)) =
    wire.decode_call("{\"fn\":\"records.list\",\"args\":[]}")
  let assert 0 = list_length_helper(args)
}

pub fn decode_call_with_args_test() {
  let assert Ok(#("fizzbuzz.classify", args)) =
    wire.decode_call("{\"fn\":\"fizzbuzz.classify\",\"args\":[15]}")
  let assert 1 = list_length_helper(args)
}

pub fn decode_call_invalid_json_test() {
  let assert Error(wire.DecodeError(message: "invalid call envelope", ..)) =
    wire.decode_call("garbage")
}

pub fn decode_call_missing_fn_test() {
  let assert Error(wire.DecodeError(message: "invalid call envelope", ..)) =
    wire.decode_call("{\"args\":[]}")
}

pub fn decode_call_missing_args_test() {
  let assert Error(wire.DecodeError(message: "invalid call envelope", ..)) =
    wire.decode_call("{\"fn\":\"foo\"}")
}

// Helper: we can't use gleam/list inside a test without importing
// it, and we want to count the opaque List(Dynamic) returned by
// decode_call. Pattern-matching the length is enough for these tests.
fn list_length_helper(items: List(a)) -> Int {
  do_length(items, 0)
}

fn do_length(items: List(a), acc: Int) -> Int {
  case items {
    [] -> acc
    [_, ..rest] -> do_length(rest, acc + 1)
  }
}
