import gleam/option.{None, Some}
import libero/remote_data.{Failure, Loading, NotAsked, Success}

// -- map --

pub fn map_success_test() {
  let assert Success(10) =
    remote_data.map(data: Success(5), transform: fn(x) { x * 2 })
}

pub fn map_failure_test() {
  let data: remote_data.RemoteData(Int, String) = Failure("err")
  let assert Failure("err") =
    remote_data.map(data:, transform: fn(x) { x * 2 })
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
