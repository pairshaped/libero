//// Error envelope for Libero RPC responses.
////
//// Every RPC response is shaped as `Result(T, RpcError(E))`, where
//// `E` is the server function's app-specific error type. The wire
//// carries this envelope uniformly regardless of whether the server
//// function itself returns a bare `T` or an explicit `Result(T, E)`.
////
//// ## Three categories of failure
////
//// 1. App errors (`AppError(e)`) are expected, domain-specific
////    failure modes the server function chose to model, such as
////    `DuplicateEmail`, `NotFound`, or `ValidationFailed`. Handled
////    by the app's UI (show a form error, navigate away, and so on).
////
//// 2. Framework errors (`MalformedRequest`, `UnknownFunction`) are
////    errors in the RPC layer itself. The request was garbage or
////    named a function that doesn't exist. Usually deployment skew
////    or a client-side bug.
////
//// 3. Internal errors (`InternalError(trace_id)`) are unexpected
////    runtime panics caught by the dispatch layer. The `trace_id`
////    is opaque to the client; the full panic details are logged
////    server-side under that id.
////
//// ## Bare-T server functions
////
//// Server functions that return a bare type (`List(Record)`, `Int`,
//// `Option(Note)`, and so on) are exposed to clients as
//// `Result(T, RpcError(Never))`, where `Never` is an uninhabited
//// type. Gleam's exhaustiveness checker understands that `Never`
//// can't be constructed, so the `AppError(_)` match arm is
//// statically unreachable and users don't need to write it.

/// Uninhabited type used for RPC functions that have no app-specific
/// errors. `RpcError(Never)` can only be constructed as
/// `MalformedRequest`, `UnknownFunction(_)`, or `InternalError(_)`.
pub type Never

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
pub type RpcError(e) {
  /// A domain-specific error returned by the server function. Only
  /// present for functions whose server signature is `Result(T, E)`.
  /// Functions returning bare `T` use `RpcError(Never)` and this
  /// variant is unreachable.
  AppError(e)

  /// The server couldn't parse the incoming call envelope.
  MalformedRequest

  /// The named RPC function doesn't exist in the server's dispatch
  /// table. Usually deployment skew or a client-side typo.
  UnknownFunction(name: String)

  /// The server function panicked while processing the request.
  /// The real details are logged server-side under this `trace_id`.
  InternalError(trace_id: String)
}
