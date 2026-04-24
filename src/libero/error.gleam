//// Error envelope for Libero RPC responses.
////
//// Every RPC response is shaped as `Result(T, RpcError)`. The wire
//// carries this envelope uniformly regardless of the server function's
//// return type.
////
//// ## Two categories of failure
////
//// 1. Framework errors (`MalformedRequest`, `UnknownFunction`) are
////    errors in the RPC layer itself. The request was garbage or
////    named a function that doesn't exist. Usually deployment skew
////    or a client-side bug.
////
//// 2. Internal errors (`InternalError(trace_id, message)`) are
////    unexpected runtime panics caught by the dispatch layer. The
////    `trace_id` is opaque to the client; the full panic details
////    are logged server-side under that id. The `message` field
////    contains a client-safe string suitable for display to end
////    users without exposing internal details.

/// Information about a server-side panic caught by the dispatch
/// layer. The generated `handle()` function returns this alongside
/// the encoded response envelope, letting the WebSocket handler
/// (or any other caller) log, report, or escalate however the
/// project prefers. Libero itself has no logging dependency; it
/// just tells you what happened and under what trace id.
pub type PanicInfo {
  PanicInfo(trace_id: String, fn_name: String, reason: String)
}

/// The error envelope for every Libero RPC response.
pub type RpcError {
  /// The server couldn't parse the incoming call envelope.
  MalformedRequest

  /// The named RPC function doesn't exist in the server's dispatch
  /// table. Usually deployment skew or a client-side typo.
  UnknownFunction(name: String)

  /// The server function panicked while processing the request.
  /// The real details are logged server-side under this `trace_id`.
  /// The `message` field contains a client-safe string suitable for
  /// display to end users (e.g. "Something went wrong, please try
  /// again"). Consumers can override it in their error-display logic
  /// or use it as-is.
  InternalError(trace_id: String, message: String)
}
