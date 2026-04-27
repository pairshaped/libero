import gleam/option.{None, Some}
import libero/error
import libero/remote_data.{
  DomainError, Failure, Loading, NotAsked, Success, TransportError,
}

// -- map --

pub fn map_success_test() {
  let assert Success(10) =
    remote_data.map(data: Success(5), transform: fn(x) { x * 2 })
}

pub fn map_failure_test() {
  let data: remote_data.RemoteData(Int, String) = Failure("err")
  let assert Failure("err") = remote_data.map(data:, transform: fn(x) { x * 2 })
}

pub fn map_loading_test() {
  let data: remote_data.RemoteData(Int, String) = Loading
  let assert Loading = remote_data.map(data:, transform: fn(x) { x * 2 })
}

pub fn map_not_asked_test() {
  let data: remote_data.RemoteData(Int, String) = NotAsked
  let assert NotAsked = remote_data.map(data:, transform: fn(x) { x * 2 })
}

// -- map_error --

pub fn map_error_failure_test() {
  let assert Failure(2) =
    remote_data.map_error(data: Failure(1), transform: fn(e) { e + 1 })
}

pub fn map_error_success_test() {
  let data: remote_data.RemoteData(Int, Int) = Success(42)
  let assert Success(42) =
    remote_data.map_error(data:, transform: fn(e) { e + 1 })
}

pub fn map_error_loading_test() {
  let data: remote_data.RemoteData(Int, Int) = Loading
  let assert Loading = remote_data.map_error(data:, transform: fn(e) { e + 1 })
}

// -- unwrap --

pub fn unwrap_success_test() {
  let assert 42 = remote_data.unwrap(data: Success(42), default: 0)
}

pub fn unwrap_loading_test() {
  let assert 0 = remote_data.unwrap(data: Loading, default: 0)
}

pub fn unwrap_failure_test() {
  let assert 0 = remote_data.unwrap(data: Failure("err"), default: 0)
}

pub fn unwrap_not_asked_test() {
  let assert 0 = remote_data.unwrap(data: NotAsked, default: 0)
}

// -- to_option --

pub fn to_option_success_test() {
  let assert Some(42) = remote_data.to_option(Success(42))
}

pub fn to_option_loading_test() {
  let assert None = remote_data.to_option(Loading)
}

pub fn to_option_failure_test() {
  let assert None = remote_data.to_option(Failure("err"))
}

pub fn to_option_not_asked_test() {
  let assert None = remote_data.to_option(NotAsked)
}

// -- format_transport_error --

pub fn format_transport_error_internal_test() {
  let assert "boom" =
    remote_data.format_transport_error(error.InternalError("trace-1", "boom"))
}

pub fn format_transport_error_unknown_function_test() {
  let assert "Unknown RPC: bad_fn" =
    remote_data.format_transport_error(error.UnknownFunction("bad_fn"))
}

pub fn format_transport_error_malformed_test() {
  let assert "Malformed request" =
    remote_data.format_transport_error(error.MalformedRequest)
}

// -- format_failure --

pub fn format_failure_routes_transport_error_test() {
  let assert "Unknown RPC: bad_fn" =
    remote_data.format_failure(
      outcome: TransportError(error.UnknownFunction("bad_fn")),
      format_domain: fn(_) { "domain" },
    )
}

pub fn format_failure_routes_domain_error_test() {
  let assert "ITEM_NOT_FOUND" =
    remote_data.format_failure(
      outcome: DomainError("ITEM_NOT_FOUND"),
      format_domain: fn(code) { code },
    )
}
