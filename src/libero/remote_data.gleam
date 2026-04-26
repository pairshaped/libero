//// Typed states for async data loading.
//// Inspired by Elm's RemoteData package.
////
//// Use instead of Bool flags + Option fields for data that loads asynchronously.
//// The view pattern matches directly on the state - impossible to show stale
//// data while loading or forget to handle errors.
////
//// `from_response` is the bridge from a libero RPC response (a Dynamic value
//// shipped from the server) to a `RemoteData` value the page stores in
//// its model. The wire shape is `Result(Result(payload, domain), RpcError)`:
//// the outer Result is libero's framework envelope, the inner Result is
//// the handler's typed return. `from_response` collapses the three
//// outcomes - domain success, domain failure, framework failure - into
//// the two post-response states (`Success` or `Failure`). The `NotAsked`
//// and `Loading` states are page-lifecycle concerns the page sets itself
//// in `init` and `update`.

import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option, None, Some}
import libero/error.{type RpcError}
import libero/wire

pub type RemoteData(value, error) {
  NotAsked
  Loading
  Failure(error)
  /// Wire-level failure that can't carry a typed domain error: malformed
  /// response, version skew between client and server, codegen bug. Kept
  /// distinct from `Failure(error)` so consumers can render different UX
  /// (e.g. "connection lost, retry" vs domain validation messaging) and
  /// so exhaustive `case` matches on `error` don't have to absorb a
  /// stringly-typed transport message.
  TransportFailure(message: String)
  Success(value)
}

/// Convenience alias that pins the error type to `RpcFailure`, mirroring
/// Elm's `WebData a = RemoteData Http.Error a` pattern. Callers write
/// `RpcData(List(Todo))` instead of `RemoteData(List(Todo), RpcFailure)`.
pub type RpcData(value) =
  RemoteData(value, RpcFailure)

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
    TransportFailure(message) -> TransportFailure(message)
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
    TransportFailure(message) -> TransportFailure(message)
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

/// Check if the data has not been requested yet.
pub fn is_not_asked(data: RemoteData(a, e)) -> Bool {
  case data {
    NotAsked -> True
    _ -> False
  }
}

/// Check if the data carries a typed domain failure.
pub fn is_failure(data: RemoteData(a, e)) -> Bool {
  case data {
    Failure(_) -> True
    _ -> False
  }
}

/// Check if the data carries a wire-level transport failure.
pub fn is_transport_failure(data: RemoteData(a, e)) -> Bool {
  case data {
    TransportFailure(_) -> True
    _ -> False
  }
}

/// Check if the data is in any error state (domain or transport).
/// Useful when the view wants to render the same error UI for both.
pub fn is_error(data: RemoteData(a, e)) -> Bool {
  case data {
    Failure(_) | TransportFailure(_) -> True
    _ -> False
  }
}

/// Reduce all five states into a single value. Each case provides its
/// own callback so the caller can return whatever shape they need
/// (e.g. an `Element(msg)` for a Lustre view).
pub fn fold(
  data data: RemoteData(a, e),
  on_not_asked on_not_asked: fn() -> b,
  on_loading on_loading: fn() -> b,
  on_failure on_failure: fn(e) -> b,
  on_transport_failure on_transport_failure: fn(String) -> b,
  on_success on_success: fn(a) -> b,
) -> b {
  case data {
    NotAsked -> on_not_asked()
    Loading -> on_loading()
    Failure(error) -> on_failure(error)
    TransportFailure(message) -> on_transport_failure(message)
    Success(value) -> on_success(value)
  }
}

/// Convert a libero RPC response (Dynamic) into a `RemoteData` value.
///
/// The wire response is `Result(Result(payload, domain_err), RpcError)`:
/// the outer Result is libero's framework envelope, the inner Result is
/// the handler's typed return.
///
/// The `format_domain` callback formats domain errors (which the page
/// owns and pattern-matches on its specific error type). Framework
/// errors (internal, unknown function, malformed request) are formatted
/// by libero's default formatter.
pub fn from_response(
  raw raw: Dynamic,
  format_domain format_domain: fn(domain) -> String,
) -> RemoteData(payload, RpcFailure) {
  // BY DESIGN: wire.coerce is an unwitnessed cast. Type safety relies on
  // both sides being built from the same shared/ types.
  let outer: Result(Dynamic, RpcError) = wire.coerce(raw)
  case outer {
    Error(rpc_err) -> Failure(format_rpc_error(rpc_err))
    Ok(inner) -> {
      let result: Result(payload, domain) = wire.coerce(inner)
      case result {
        Ok(payload) -> Success(payload)
        Error(domain_err) ->
          Failure(DomainFailure(message: format_domain(domain_err)))
      }
    }
  }
}

/// Default formatter for framework-level RPC errors.
/// Domain errors travel inside `Ok(Error(domain))` and are formatted
/// by the caller's `format_domain` function.
fn format_rpc_error(err: RpcError) -> RpcFailure {
  case err {
    error.InternalError(_, message) -> FrameworkFailure(message:)
    error.UnknownFunction(name) ->
      FrameworkFailure(message: "Unknown RPC: " <> name)
    error.MalformedRequest -> FrameworkFailure(message: "Malformed request")
  }
}
