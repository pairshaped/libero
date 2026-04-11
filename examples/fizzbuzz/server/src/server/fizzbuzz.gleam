//// FizzBuzz over RPC.
////
//// Three RPC functions illustrating different libero features:
////
////   - `classify`   bare `String` return, single arg
////   - `range`      wrapped `Result(List(String), String)` return,
////                  demonstrates the app-error envelope
////   - `crash`      bare return that intentionally panics to show
////                  libero's panic recovery + trace_id flow

import gleam/int

/// @rpc
pub fn classify(n n: Int) -> String {
  case int.modulo(n, 3), int.modulo(n, 5) {
    Ok(0), Ok(0) -> "FizzBuzz"
    Ok(0), _ -> "Fizz"
    _, Ok(0) -> "Buzz"
    _, _ -> int.to_string(n)
  }
}

/// @rpc
///
/// Generate FizzBuzz labels for every integer from `from` to `to`
/// inclusive. Returns an app-specific error when the range is
/// inverted. Libero wraps this in `Result(List(String), RpcError(String))`
/// on the client side — the String in `AppError(String)` is this
/// function's domain error, distinct from libero's framework errors
/// (MalformedRequest, UnknownFunction, InternalError).
pub fn range(from from: Int, to to: Int) -> Result(List(String), String) {
  case from <= to {
    False -> Error("from must be <= to")
    True -> Ok(build_labels(current: to, from: from, acc: []))
  }
}

/// Walk `current` down to `from`, prepending each classified value to
/// an accumulator. Iterating downward means we cons in natural order
/// and the resulting list is already sorted ascending — no reversal
/// needed.
fn build_labels(
  current current: Int,
  from from: Int,
  acc acc: List(String),
) -> List(String) {
  case current < from {
    True -> acc
    False ->
      build_labels(current: current - 1, from: from, acc: [
        classify(n: current),
        ..acc
      ])
  }
}

/// @rpc
///
/// Intentionally panics when you pass the literal label "boom". Libero's
/// try_call wrapper catches the panic, generates a trace_id, returns an
/// `InternalError(trace_id)` envelope to the client, and bubbles a
/// `PanicInfo` up to the WebSocket handler for server-side logging. Use
/// this to see what happens when server code raises unexpectedly — the
/// client sees an opaque trace_id, the server logs the full context.
pub fn crash(label label: String) -> String {
  case label {
    "boom" -> panic as "you asked for it"
    _ -> "no boom — call with label: \"boom\" to crash"
  }
}
