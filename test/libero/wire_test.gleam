//// Wire-format tests for libero/wire (ETF).
////
//// Encode→decode roundtrips live in wire_roundtrip_test.gleam.
//// This file covers decode_call envelope parsing, error handling,
//// and the encode_call/decode_call symmetric pair.

import gleam/dynamic.{type Dynamic}
import gleam/option.{None, Some}
import libero/wire

// ---------- Call envelope decoding (call envelope format: {module, value}) ----------

pub fn decode_call_with_nil_value_test() {
  // call envelope: {<<"shared/records">>, nil}
  let envelope = encode_call_envelope("shared/records", coerce(Nil))
  let assert Ok(#("shared/records", _value)) = wire.decode_call(envelope)
}

pub fn decode_call_with_int_value_test() {
  // call envelope: {<<"shared/fizzbuzz">>, 15}
  let envelope = encode_call_envelope("shared/fizzbuzz", coerce(15))
  let assert Ok(#("shared/fizzbuzz", value)) = wire.decode_call(envelope)
  let result: Int = unsafe_coerce(value)
  let assert 15 = result
}

pub fn decode_call_with_string_value_test() {
  // call envelope: {<<"shared/records">>, "hello"}
  let envelope = encode_call_envelope("shared/records", coerce("hello"))
  let assert Ok(#("shared/records", value)) = wire.decode_call(envelope)
  let result: String = unsafe_coerce(value)
  let assert "hello" = result
}

pub fn decode_call_invalid_binary_test() {
  let assert Error(wire.DecodeError(message: "invalid ETF binary")) =
    wire.decode_call(<<0, 1, 2, 3>>)
}

pub fn decode_call_wrong_shape_test() {
  // Encode a plain integer instead of a {module, value} tuple
  let bad = ffi_encode(coerce(42))
  let assert Error(wire.DecodeError(
    message: "invalid call envelope: expected {binary, value} tuple",
  )) = wire.decode_call(bad)
}

// ---------- Direct encode → decode round-trip ----------
//
// These exercise the public `wire.encode` and `wire.decode` functions
// as a symmetric pair, the way consumers use them for non-RPC paths
// (e.g. passing server-rendered state into a Lustre SPA via flags).
// Distinct from the call-envelope round-trips in wire_roundtrip_test.
// those wrap the value in `{name, args}` and use `decode_call`.

pub fn roundtrip_int_via_decode_test() {
  let result: Int = wire.decode(wire.encode(42))
  let assert 42 = result
}

pub fn roundtrip_string_via_decode_test() {
  let result: String = wire.decode(wire.encode("hello"))
  let assert "hello" = result
}

pub fn roundtrip_bool_via_decode_test() {
  let result: Bool = wire.decode(wire.encode(True))
  let assert True = result
}

pub fn roundtrip_list_via_decode_test() {
  let result: List(Int) = wire.decode(wire.encode([1, 2, 3]))
  let assert [1, 2, 3] = result
}

pub fn roundtrip_option_some_via_decode_test() {
  let result: option.Option(String) = wire.decode(wire.encode(Some("x")))
  let assert Some("x") = result
}

pub fn roundtrip_option_none_via_decode_test() {
  let result: option.Option(Int) = wire.decode(wire.encode(None))
  let assert None = result
}

pub fn roundtrip_tuple_via_decode_test() {
  let result: #(String, Int, Bool) =
    wire.decode(wire.encode(#("session", 42, True)))
  let assert #("session", 42, True) = result
}

// ---------- Helpers ----------

fn encode_call_envelope(module: String, value: Dynamic) -> BitArray {
  ffi_encode(coerce(#(module, value)))
}

@external(erlang, "libero_ffi", "encode")
fn ffi_encode(value: Dynamic) -> BitArray

@external(erlang, "gleam_stdlib", "identity")
fn coerce(value: a) -> Dynamic

@external(erlang, "gleam_stdlib", "identity")
fn unsafe_coerce(value: Dynamic) -> a

pub fn encode_call_decode_call_roundtrip_string_test() {
  let encoded = wire.encode_call(module: "core/messages", msg: "hello")
  let assert Ok(#("core/messages", msg)) = wire.decode_call(encoded)
  let decoded: String = wire.coerce(msg)
  let assert "hello" = decoded
}

pub fn encode_call_decode_call_roundtrip_int_test() {
  let encoded = wire.encode_call(module: "core/messages", msg: 42)
  let assert Ok(#("core/messages", msg)) = wire.decode_call(encoded)
  let decoded: Int = wire.coerce(msg)
  let assert 42 = decoded
}

pub fn encode_call_decode_call_roundtrip_tuple_test() {
  let encoded = wire.encode_call(module: "my/module", msg: #("a", 1))
  let assert Ok(#("my/module", msg)) = wire.decode_call(encoded)
  let decoded: #(String, Int) = wire.coerce(msg)
  let assert #("a", 1) = decoded
}
