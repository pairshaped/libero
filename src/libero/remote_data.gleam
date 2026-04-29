//// Typed states for async data loading.
//// Inspired by Elm's RemoteData package.
////
//// Use instead of Bool flags + Option fields for data that loads
//// asynchronously. The view pattern matches directly on the state -
//// impossible to show stale data while loading or forget to handle errors.
////
//// Generated RPC stubs build `RpcData` directly: the per-endpoint
//// `decode_response_<fn>` FFI returns an `RpcData(payload, domain)` that
//// the page stores in its model. `NotAsked` and `Loading` are page-lifecycle
//// states the page sets itself in `init` and `update`. `Failure` carries
//// either a `TransportError(RpcError)` (framework / wire-level) or a typed
//// `DomainError(domain)` from the handler's own error type.

import gleam/option.{type Option, None, Some}
import libero/error.{type RpcError}

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

/// Combine two independent `RemoteData` values with a function. Returns
/// `Success` only when both inputs are `Success`. Short-circuits on the
/// first `Failure` found (in either position), or `Loading` if either is
/// `Loading` and neither has failed.
///
/// Useful in `init` to batch parallel RPC calls into a single state
/// transition:
///
/// ```
/// let result = remote_data.map2(config_rd, items_rd, fn(c, i) {
///   #(c, i)
/// })
/// ```
pub fn map2(
  a a: RemoteData(a, e),
  b b: RemoteData(b, e),
  combine combine: fn(a, b) -> c,
) -> RemoteData(c, e) {
  case a, b {
    Success(a), Success(b) -> Success(combine(a, b))
    Failure(e), _ -> Failure(e)
    _, Failure(e) -> Failure(e)
    Loading, _ -> Loading
    _, Loading -> Loading
    _, _ -> NotAsked
  }
}

/// Monadic bind for chaining dependent async work. When the data is
/// `Success`, apply `f` to the value and return its result. Otherwise
/// propagate the current state unchanged.
///
/// RPC calls that depend on a prior result usually live in separate
/// `update` arms rather than inside `init`, so this is less common than
/// `map` or `map2` — but available when callers need it.
pub fn try(
  data data: RemoteData(a, e),
  f f: fn(a) -> RemoteData(b, e),
) -> RemoteData(b, e) {
  case data {
    Success(value) -> f(value)
    NotAsked -> NotAsked
    Loading -> Loading
    Failure(error) -> Failure(error)
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

/// Default formatter for framework-level transport errors. Useful when
/// the caller wants a single string for `RpcError` values rather than
/// pattern-matching each variant.
pub fn format_transport_error(err: RpcError) -> String {
  case err {
    error.InternalError(_, message) -> message
    error.UnknownFunction(name) -> "Unknown RPC: " <> name
    error.MalformedRequest -> "Malformed request"
  }
}

/// Render an `RpcOutcome` as a single user-facing string. The caller
/// supplies a formatter for their domain error type; transport errors
/// are routed through `format_transport_error`.
///
/// Use this anywhere two arms differ only by which formatter runs. In
/// views:
///
/// ```
/// Failure(outcome) -> render(format_failure(outcome, format_my_error))
/// ```
///
/// In an update reducer that surfaces a flash message:
///
/// ```
/// LoadResult(Failure(outcome)) -> #(
///   model,
///   effect.none(),
///   Some(#(Danger, format_failure(outcome, format_my_error))),
/// )
/// ```
///
/// The match becomes exhaustive over `RpcOutcome`, so no
/// `Failure(_)` catch-all is needed and the per-tier `DomainError(err)` /
/// `TransportError(rpc_err)` arms collapse into one.
pub fn format_failure(
  outcome outcome: RpcOutcome(domain),
  format_domain format_domain: fn(domain) -> String,
) -> String {
  case outcome {
    TransportError(err) -> format_transport_error(err)
    DomainError(err) -> format_domain(err)
  }
}
