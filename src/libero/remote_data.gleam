//// Typed states for async data loading.
//// Inspired by Elm's RemoteData package.
////
//// Use instead of Bool flags + Option fields for data that loads asynchronously.
//// The view pattern matches directly on the state - impossible to show stale
//// data while loading or forget to handle errors.
////
//// `to_remote` is the bridge from a libero RPC response (a Dynamic value
//// shipped from the server) to a `RemoteData` value the page stores in
//// its model. It collapses three wire outcomes - domain success, domain
//// failure, framework failure - into the two post-response states
//// (`Success` or `Failure`). The `NotAsked` and `Loading` states are
//// page-lifecycle concerns the page sets itself in `init` and `update`.

import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option, None, Some}
import libero/error.{type RpcError}
import libero/wire

pub type RemoteData(value, error) {
  NotAsked
  Loading
  Failure(error)
  Success(value)
}

/// Error type for formatted RPC failures. Distinguishes domain errors
/// (formatted by the caller) from framework errors (formatted by libero).
pub type RpcFailure {
  DomainFailure(message: String)
  FrameworkFailure(message: String)
}

/// Apply a function to the success value.
pub fn map(
  data data: RemoteData(a, e),
  transform transform: fn(a) -> b,
) -> RemoteData(b, e) {
  case data {
    NotAsked -> NotAsked
    Loading -> Loading
    Failure(error) -> Failure(error)
    Success(value) -> Success(transform(value))
  }
}

/// Apply a function to the error value.
pub fn map_error(
  data data: RemoteData(a, e1),
  transform transform: fn(e1) -> e2,
) -> RemoteData(a, e2) {
  case data {
    NotAsked -> NotAsked
    Loading -> Loading
    Failure(error) -> Failure(transform(error))
    Success(value) -> Success(value)
  }
}

/// Extract the success value, or return a default.
pub fn unwrap(data data: RemoteData(a, e), default default: a) -> a {
  case data {
    Success(value) -> value
    _ -> default
  }
}

/// Convert to Option - Some for Success, None for everything else.
pub fn to_option(data: RemoteData(a, e)) -> Option(a) {
  case data {
    Success(value) -> Some(value)
    _ -> None
  }
}

/// Check if the data is loaded successfully.
pub fn is_success(data: RemoteData(a, e)) -> Bool {
  case data {
    Success(_) -> True
    _ -> False
  }
}

/// Check if the data is currently loading.
pub fn is_loading(data: RemoteData(a, e)) -> Bool {
  case data {
    Loading -> True
    _ -> False
  }
}

/// Convert a libero RPC response (Dynamic) into a `RemoteData` value.
///
/// The server-side dispatch ships the full MsgFromServer envelope so the
/// wire response is `Result(MsgFromServer.Variant(Result(payload, domain_err)), RpcError(app_err))`.
/// This helper peels the MsgFromServer wrapper and collapses the result
/// into the two post-response states.
///
/// The `format_domain` callback formats domain errors (which the page
/// owns and pattern-matches on its specific error type). Framework
/// errors (internal, unknown function, malformed request, server
/// AppError) are formatted by libero's default formatter.
pub fn to_remote(
  raw raw: Dynamic,
  format_domain format_domain: fn(domain) -> String,
) -> RemoteData(payload, RpcFailure) {
  // Safety: wire.coerce casts are safe here because both ends use the same
  // Gleam types over ETF — the server encodes and the client decodes the
  // same Result/MsgFromServer structures. A type mismatch would indicate a
  // version skew between server and client, not a logic error.
  let outer: Result(Dynamic, RpcError(app)) = wire.coerce(raw)
  case outer {
    Error(rpc_err) -> Failure(format_rpc_error(rpc_err))
    Ok(wrapped) -> {
      let inner: Dynamic = peel_msg_wrapper(wrapped)
      let result: Result(payload, domain) = wire.coerce(inner)
      case result {
        Ok(payload) -> Success(payload)
        Error(domain_err) ->
          Failure(DomainFailure(message: format_domain(domain_err)))
      }
    }
  }
}

/// Extract the single payload field from a MsgFromServer variant wrapper.
/// On Erlang, Gleam variants compile to `{atom, Field}` tuples;
/// `element(2, Tuple)` extracts the payload.
/// On JavaScript, variants compile to class instances where the first
/// field is stored at index `[0]` (i.e. `wrapper[0]`).
@external(erlang, "libero_ffi", "peel_msg_wrapper")
@external(javascript, "./remote_data_ffi.mjs", "peelMsgWrapper")
fn peel_msg_wrapper(wrapper: Dynamic) -> Dynamic {
  let _ = wrapper
  panic as "unreachable"
}

/// Adapter for action responses that the page wants as a flat `Result`
/// rather than `RemoteData`. Useful when the response only feeds a flash
/// message or triggers a redirect - the page never needs to render
/// `NotAsked`/`Loading` states for the action result itself.
pub fn to_result(
  raw raw: Dynamic,
  format_domain format_domain: fn(domain) -> String,
) -> Result(payload, RpcFailure) {
  case to_remote(raw: raw, format_domain: format_domain) {
    Success(payload) -> Ok(payload)
    Failure(err) -> Error(err)
    NotAsked | Loading ->
      Error(FrameworkFailure(
        message: "Unexpected response state: to_result called on a non-response",
      ))
  }
}

/// Default formatter for framework-level RPC errors.
/// Domain errors travel inside `Ok(Error(domain))` and are formatted
/// by the caller's `format_domain` function.
fn format_rpc_error(err: RpcError(a)) -> RpcFailure {
  case err {
    error.AppError(_) -> FrameworkFailure(message: "Server application error")
    error.InternalError(_, message) -> FrameworkFailure(message:)
    error.UnknownFunction(name) ->
      FrameworkFailure(message: "Unknown RPC: " <> name)
    error.MalformedRequest -> FrameworkFailure(message: "Malformed request")
  }
}
