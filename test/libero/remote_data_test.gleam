import gleam/dynamic.{type Dynamic}
import gleam/option.{None, Some}
import libero/error
import libero/remote_data.{
  type RpcData, DomainFailure, Failure, FrameworkFailure, Loading, NotAsked,
  Success,
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

// -- is_success --

pub fn is_success_true_test() {
  let assert True = remote_data.is_success(Success(1))
}

pub fn is_success_false_for_loading_test() {
  let assert False = remote_data.is_success(Loading)
}

pub fn is_success_false_for_failure_test() {
  let assert False = remote_data.is_success(Failure("err"))
}

pub fn is_success_false_for_not_asked_test() {
  let assert False = remote_data.is_success(NotAsked)
}

// -- is_loading --

pub fn is_loading_true_test() {
  let assert True = remote_data.is_loading(Loading)
}

pub fn is_loading_false_for_success_test() {
  let assert False = remote_data.is_loading(Success(1))
}

pub fn is_loading_false_for_failure_test() {
  let assert False = remote_data.is_loading(Failure("err"))
}

pub fn is_loading_false_for_not_asked_test() {
  let assert False = remote_data.is_loading(NotAsked)
}

// -- from_response (response decoding) --
//
// Wire shape: Result(Result(payload, domain), RpcError) — outer Result
// is libero's framework envelope, inner Result is the handler's typed
// return.

pub type Item {
  Item(id: Int, title: String)
}

pub type DomainError {
  NotFound
}

pub fn from_response_success_extracts_payload_test() {
  let wire: Dynamic = coerce(Ok(Ok(Item(1, "Buy milk"))))
  let rd: RpcData(Item) =
    remote_data.from_response(raw: wire, format_domain: format_domain)
  let assert Success(Item(1, "Buy milk")) = rd
}

pub fn from_response_success_extracts_list_payload_test() {
  let items = [Item(1, "Buy milk"), Item(2, "Walk dog")]
  let wire: Dynamic = coerce(Ok(Ok(items)))
  let rd: RpcData(List(Item)) =
    remote_data.from_response(raw: wire, format_domain: format_domain)
  let assert Success([Item(1, "Buy milk"), Item(2, "Walk dog")]) = rd
}

pub fn from_response_domain_error_test() {
  let wire: Dynamic = coerce(Ok(Error(NotFound)))
  let rd: RpcData(Item) =
    remote_data.from_response(raw: wire, format_domain: format_domain)
  let assert Failure(DomainFailure(message: "Not found")) = rd
}

pub fn from_response_rpc_error_test() {
  let wire: Dynamic = coerce(Error(error.MalformedRequest))
  let rd: RpcData(Item) =
    remote_data.from_response(raw: wire, format_domain: format_domain)
  let assert Failure(FrameworkFailure(message: "Malformed request")) = rd
}

pub fn from_response_unknown_function_error_test() {
  let wire: Dynamic = coerce(Error(error.UnknownFunction("bad_fn")))
  let rd: RpcData(Item) =
    remote_data.from_response(raw: wire, format_domain: format_domain)
  let assert Failure(FrameworkFailure(message: "Unknown RPC: bad_fn")) = rd
}

pub fn from_response_internal_error_test() {
  let wire: Dynamic =
    coerce(Error(error.InternalError("trace-123", "Something went wrong")))
  let rd: RpcData(Item) =
    remote_data.from_response(raw: wire, format_domain: format_domain)
  let assert Failure(FrameworkFailure(message: "Something went wrong")) = rd
}

// -- helpers --

fn format_domain(err: DomainError) -> String {
  case err {
    NotFound -> "Not found"
  }
}

@external(erlang, "gleam_stdlib", "identity")
fn coerce(value: a) -> Dynamic
