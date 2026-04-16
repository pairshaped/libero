import gleam/list
import libero/gen_error
import libero/scanner

pub fn scan_empty_dir_returns_no_modules_error_test() {
  let result =
    scanner.scan_message_modules(shared_src: "/tmp/nonexistent_libero_test_xyz")
  let assert Error(errors) = result
  let assert True =
    list.any(errors, fn(e) {
      case e {
        gen_error.NoMessageModules(_) -> True
        _ -> False
      }
    })
}

pub fn scan_todos_example_finds_todos_module_test() {
  let assert Ok(#(modules, _module_files)) =
    scanner.scan_message_modules(
      shared_src: "examples/todos/shared/src/shared",
    )
  let assert True = list.length(modules) == 1
  let assert [m] = modules
  let assert True = m.has_msg_from_client
  let assert True = m.has_msg_from_server
  // Module path should be "shared/todos"
  let assert True = m.module_path == "shared/todos"
}

pub fn validate_todos_example_passes_test() {
  let assert Ok(#(modules, _module_files)) =
    scanner.scan_message_modules(
      shared_src: "examples/todos/shared/src/shared",
    )
  let assert Ok(updated_modules) =
    scanner.validate_conventions(
      message_modules: modules,
      server_src: "examples/todos/server/src",
    )
  // Handler should be discovered
  let assert [m] = updated_modules
  let assert True = m.handler_modules == ["server/store"]
}

pub fn validate_missing_shared_state_test() {
  let modules = [
    scanner.MessageModule(
      module_path: "shared/todos",
      file_path: "/tmp/todos.gleam",
      has_msg_from_client: True,
      has_msg_from_server: True,
      handler_modules: [],
    ),
  ]
  let assert Error(errors) =
    scanner.validate_conventions(
      message_modules: modules,
      server_src: "/tmp/nonexistent_server_src",
    )
  let assert True =
    list.any(errors, fn(e) {
      case e {
        gen_error.MissingSharedState(_) -> True
        _ -> False
      }
    })
}

pub fn validate_missing_app_error_test() {
  let modules = [
    scanner.MessageModule(
      module_path: "shared/todos",
      file_path: "/tmp/todos.gleam",
      has_msg_from_client: True,
      has_msg_from_server: True,
      handler_modules: [],
    ),
  ]
  let assert Error(errors) =
    scanner.validate_conventions(
      message_modules: modules,
      server_src: "/tmp/nonexistent_server_src",
    )
  let assert True =
    list.any(errors, fn(e) {
      case e {
        gen_error.MissingAppError(_) -> True
        _ -> False
      }
    })
}

pub fn validate_missing_handler_test() {
  let modules = [
    scanner.MessageModule(
      module_path: "shared/todos",
      file_path: "/tmp/todos.gleam",
      has_msg_from_client: True,
      has_msg_from_server: True,
      handler_modules: [],
    ),
  ]
  let assert Error(errors) =
    scanner.validate_conventions(
      message_modules: modules,
      server_src: "/tmp/nonexistent_server_src",
    )
  let assert True =
    list.any(errors, fn(e) {
      case e {
        gen_error.MissingHandler(_, _) -> True
        _ -> False
      }
    })
}
