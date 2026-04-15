import gleam/list
import libero

pub fn scan_empty_dir_returns_no_modules_error_test() {
  let result =
    libero.scan_message_modules(shared_src: "/tmp/nonexistent_libero_test_xyz")
  let assert Error(errors) = result
  let assert True =
    list.any(errors, fn(e) {
      case e {
        libero.NoMessageModules(_) -> True
        _ -> False
      }
    })
}

pub fn scan_todos_example_finds_todos_module_test() {
  let assert Ok(#(modules, _module_files)) =
    libero.scan_message_modules(
      shared_src: "examples/todos/shared/src/shared",
    )
  let assert True = list.length(modules) == 1
  let assert [m] = modules
  let assert True = m.has_to_server
  let assert True = m.has_to_client
  // Module path should be "shared/todos"
  let assert True = m.module_path == "shared/todos"
}

pub fn validate_todos_example_passes_test() {
  let assert Ok(#(modules, _module_files)) =
    libero.scan_message_modules(
      shared_src: "examples/todos/shared/src/shared",
    )
  let errors =
    libero.validate_conventions(
      message_modules: modules,
      server_src: "examples/todos/server/src",
    )
  let assert True = list.is_empty(errors)
}

pub fn validate_missing_shared_state_test() {
  let modules = [
    libero.MessageModule(
      module_path: "shared/todos",
      file_path: "/tmp/todos.gleam",
      has_to_server: True,
      has_to_client: True,
    ),
  ]
  let errors =
    libero.validate_conventions(
      message_modules: modules,
      server_src: "/tmp/nonexistent_server_src",
    )
  let assert True =
    list.any(errors, fn(e) {
      case e {
        libero.MissingSharedState(_) -> True
        _ -> False
      }
    })
}

pub fn validate_missing_app_error_test() {
  let modules = [
    libero.MessageModule(
      module_path: "shared/todos",
      file_path: "/tmp/todos.gleam",
      has_to_server: True,
      has_to_client: True,
    ),
  ]
  let errors =
    libero.validate_conventions(
      message_modules: modules,
      server_src: "/tmp/nonexistent_server_src",
    )
  let assert True =
    list.any(errors, fn(e) {
      case e {
        libero.MissingAppError(_) -> True
        _ -> False
      }
    })
}

pub fn validate_missing_handler_test() {
  let modules = [
    libero.MessageModule(
      module_path: "shared/todos",
      file_path: "/tmp/todos.gleam",
      has_to_server: True,
      has_to_client: True,
    ),
  ]
  let errors =
    libero.validate_conventions(
      message_modules: modules,
      server_src: "/tmp/nonexistent_server_src",
    )
  let assert True =
    list.any(errors, fn(e) {
      case e {
        libero.MissingHandler(_, _) -> True
        _ -> False
      }
    })
}
