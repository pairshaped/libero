//// Typed states for async data loading.
//// Inspired by Elm's RemoteData package.
////
//// Use instead of Bool flags + Option fields for data that loads
//// asynchronously. The view pattern matches directly on the state -
//// impossible to show stale data while loading or forget to handle errors.
////
//// `from_response` is the bridge from a libero RPC response (a Dynamic
//// value shipped from the server) to an `RpcData` value the page stores
//// in its model. The wire shape is `Result(Result(payload, domain), RpcError)`:
//// the outer Result is libero's framework envelope, the inner Result is
//// the handler's typed return. Transport failures become
//// `Failure(TransportError(rpc))`, domain failures become
//// `Failure(DomainError(domain))`, and a clean round-trip becomes
//// `Success(payload)`. `NotAsked` and `Loading` are page-lifecycle states
//// the page sets itself in `init` and `update`.

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

/// Composite error for an RPC outcome. Keeps transport-level failures
/// (framework errors, version skew, malformed responses) typed as
/// `RpcError` while preserving the caller's typed `domain` error from
/// the handler. Lets view code pattern-match on the tier it cares
/// about, or fall through with `Failure(_)` for a generic message.
pub type RpcOutcome(domain) {
  TransportError(RpcError)
  DomainError(domain)
}

/// Convenience alias for `RemoteData` pinned to `RpcOutcome`. Mirrors
/// Elm's `WebData a = RemoteData Http.Error a`. Callers write
/// `RpcData(List(Todo), TodoError)` instead of
/// `RemoteData(List(Todo), RpcOutcome(TodoError))`.
pub type RpcData(value, domain) =
  RemoteData(value, RpcOutcome(domain))

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

/// Check if the data has not been requested yet.
pub fn is_not_asked(data: RemoteData(a, e)) -> Bool {
  case data {
    NotAsked -> True
    _ -> False
  }
}

/// Check if the data is in a failure state.
pub fn is_failure(data: RemoteData(a, e)) -> Bool {
  case data {
    Failure(_) -> True
    _ -> False
  }
}

/// Reduce all four states into a single value. Each case provides its
/// own callback so the caller can return whatever shape they need
/// (e.g. an `Element(msg)` for a Lustre view).
pub fn fold(
  data data: RemoteData(a, e),
  on_not_asked on_not_asked: fn() -> b,
  on_loading on_loading: fn() -> b,
  on_failure on_failure: fn(e) -> b,
  on_success on_success: fn(a) -> b,
) -> b {
  case data {
    NotAsked -> on_not_asked()
    Loading -> on_loading()
    Failure(error) -> on_failure(error)
    Success(value) -> on_success(value)
  }
}

/// Convert a libero RPC response (Dynamic) into an `RpcData` value.
///
/// The wire response is `Result(Result(payload, domain), RpcError)`:
/// the outer Result is libero's framework envelope, the inner Result
/// is the handler's typed return. Transport errors become
/// `Failure(TransportError(rpc))`. Domain errors become
/// `Failure(DomainError(domain))`. A clean round-trip becomes
/// `Success(payload)`.
pub fn from_response(raw raw: Dynamic) -> RpcData(payload, domain) {
  // BY DESIGN: wire.coerce is an unwitnessed cast. Type safety relies on
  // both sides being built from the same shared/ types.
  let outer: Result(Dynamic, RpcError) = wire.coerce(raw)
  case outer {
    Error(rpc_err) -> Failure(TransportError(rpc_err))
    Ok(inner) -> {
      let result: Result(payload, domain) = wire.coerce(inner)
      case result {
        Ok(payload) -> Success(payload)
        Error(domain_err) -> Failure(DomainError(domain_err))
      }
    }
  }
}

/// Default formatter for framework-level RPC errors. Useful when the
/// caller wants a single string for transport failures rather than
/// pattern-matching each `RpcError` variant.
pub fn format_rpc_error(err: RpcError) -> String {
  case err {
    error.InternalError(_, message) -> message
    error.UnknownFunction(name) -> "Unknown RPC: " <> name
    error.MalformedRequest -> "Malformed request"
  }
}
