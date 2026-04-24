//// Tests for libero/error wire roundtrip and InternalError message field.

import gleam/dynamic.{type Dynamic}
import libero/error.{type RpcError, InternalError}
import libero/wire

/// InternalError carries a client-safe message that consumers can
/// display directly. Verify the field survives construction and
/// partial pattern matching.
pub fn internal_error_message_accessible_via_pattern_match_test() {
  let err: RpcError =
    InternalError(
      trace_id: "trace42",
      message: "Something went wrong, please try again.",
    )
  let assert InternalError(
    message: "Something went wrong, please try again.",
    ..,
  ) = err
}

/// Verify the full error envelope survives an ETF roundtrip through
/// a call envelope. This exercises the BEAM's atom encoding of
/// the InternalError constructor tag.
pub fn internal_error_roundtrips_through_wire_test() {
  let value: Result(String, RpcError) =
    Error(InternalError(
      trace_id: "abc123",
      message: "Something went wrong, please try again.",
    ))
  let encoded = wire.encode(value)
  // Wrap in a call envelope {module, request_id, value} and decode to verify structure survives.
  let envelope = ffi_encode(coerce(#("shared/test", 0, coerce(encoded))))
  let assert Ok(#("shared/test", 0, rebuilt)) = wire.decode_call(envelope)
  let decoded: Result(String, RpcError) = wire.decode(unsafe_coerce(rebuilt))
  let assert Error(InternalError(
    trace_id: "abc123",
    message: "Something went wrong, please try again.",
  )) = decoded
}

@external(erlang, "libero_ffi", "encode")
fn ffi_encode(value: Dynamic) -> BitArray

@external(erlang, "gleam_stdlib", "identity")
fn coerce(value: a) -> Dynamic

@external(erlang, "gleam_stdlib", "identity")
fn unsafe_coerce(value: Dynamic) -> a
