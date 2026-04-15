//// Tests for wire.decode_safe - the Result-returning decoder.

import libero/wire

pub fn decode_safe_valid_int_test() {
  let encoded = wire.encode(42)
  let result: Result(Int, wire.DecodeError) = wire.decode_safe(encoded)
  let assert Ok(42) = result
}

pub fn decode_safe_valid_string_test() {
  let encoded = wire.encode("hello")
  let result: Result(String, wire.DecodeError) = wire.decode_safe(encoded)
  let assert Ok("hello") = result
}

pub fn decode_safe_valid_list_test() {
  let encoded = wire.encode([1, 2, 3])
  let result: Result(List(Int), wire.DecodeError) = wire.decode_safe(encoded)
  let assert Ok([1, 2, 3]) = result
}

pub fn decode_safe_garbage_input_test() {
  let result: Result(Int, wire.DecodeError) = wire.decode_safe(<<0, 1, 2, 3>>)
  let assert Error(wire.DecodeError(message: _)) = result
}

pub fn decode_safe_empty_input_test() {
  let result: Result(Int, wire.DecodeError) = wire.decode_safe(<<>>)
  let assert Error(wire.DecodeError(message: _)) = result
}

pub fn decode_safe_truncated_etf_test() {
  // Valid ETF version byte (131) followed by incomplete data
  let result: Result(Int, wire.DecodeError) = wire.decode_safe(<<131>>)
  let assert Error(wire.DecodeError(message: _)) = result
}
