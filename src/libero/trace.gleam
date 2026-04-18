//// Panic-catching + trace_id primitives for the dispatch layer.
////
//// `try_call(action)` runs a zero-arg function inside an Erlang
//// try/catch and returns `Ok(result)` on success or `Error(reason)`
//// where `reason` is the stringified exception.
////
//// `new_trace_id()` returns a 12-character base16-encoded random id,
//// suitable for correlating log lines with RPC error responses.
////
//// **Logging is intentionally not part of this module.** Libero stays
//// free of wisp/logging dependencies so it can be used in any
//// Erlang-target consumer. The generated dispatch code uses
//// `io.println_error` as a default logger; consumers that want
//// structured logging can wrap the primitives in their own module.

import gleam/bit_array
import gleam/crypto

/// Run the given function, catching any panic. Returns the result on
/// success; on failure, returns the stringified exception reason.
/// Callers typically pair this with a trace id from `new_trace_id` and
/// log both under a single correlation id.
/// nolint: stringly_typed_error -- wraps OTP catch; exception reason is inherently a string
pub fn try_call(action: fn() -> a) -> Result(a, String) {
  do_try_call(action)
}

/// Generate a fresh 12-character base16 random id. 6 bytes of entropy
/// is plenty for log correlation and keeps the id short enough to fit
/// in a devtools view.
pub fn new_trace_id() -> String {
  crypto.strong_random_bytes(6) |> bit_array.base16_encode
}

// Note: there's no catch_panic convenience wrapper here. The
// generated dispatch code handles panics inline by calling
// `try_call` + `new_trace_id` and bubbling a `PanicInfo` value up
// through its return type. This keeps libero free of any logging
// dependency. Consumers decide what to do with panic info in their
// WebSocket handler, not in library code.

@external(erlang, "libero_ffi", "try_call")
// nolint: stringly_typed_error
fn do_try_call(action: fn() -> a) -> Result(a, String)
