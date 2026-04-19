import gleam/list
import gleam/string
import libero/gen_error
import libero/scanner
import simplifile

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
    scanner.scan_message_modules(shared_src: "examples/todos/src/core")
  let assert True = list.length(modules) == 1
  let assert [m] = modules
  let assert True = m.has_msg_from_client
  let assert True = m.has_msg_from_server
  // Module path should be "core/messages"
  let assert True = m.module_path == "core/messages"
}

pub fn validate_todos_example_passes_test() {
  let assert Ok(#(modules, _module_files)) =
    scanner.scan_message_modules(shared_src: "examples/todos/src/core")
  let assert Ok(updated_modules) =
    scanner.validate_conventions(
      message_modules: modules,
      server_src: "examples/todos/src",
      shared_state_path: "examples/todos/src/core/shared_state.gleam",
      app_error_path: "examples/todos/src/core/app_error.gleam",
    )
  // Handler should be discovered
  let assert [m] = updated_modules
  let assert True = m.handler_modules == ["core/handler"]
}

pub fn scaffold_shared_state_when_missing_test() {
  let dir = "build/.test_scaffold"
  let server_dir = dir <> "/server"
  let _ = simplifile.create_directory_all(server_dir)
  let modules = [
    scanner.MessageModule(
      module_path: "core/messages",
      file_path: "/tmp/todos.gleam",
      has_msg_from_client: True,
      has_msg_from_server: True,
      handler_modules: [],
    ),
  ]
  // Validation will scaffold missing files, but still error on missing handler
  let assert Error(_errors) =
    scanner.validate_conventions(
      message_modules: modules,
      server_src: dir,
      shared_state_path: server_dir <> "/shared_state.gleam",
      app_error_path: server_dir <> "/app_error.gleam",
    )
  // shared_state.gleam should have been scaffolded
  let assert Ok(content) = simplifile.read(server_dir <> "/shared_state.gleam")
  let assert True = string.contains(content, "pub type SharedState")
  let assert True = string.contains(content, "pub fn new()")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([dir])
}

pub fn scaffold_app_error_when_missing_test() {
  let dir = "build/.test_scaffold"
  let server_dir = dir <> "/server"
  let _ = simplifile.create_directory_all(server_dir)
  let modules = [
    scanner.MessageModule(
      module_path: "core/messages",
      file_path: "/tmp/todos.gleam",
      has_msg_from_client: True,
      has_msg_from_server: True,
      handler_modules: [],
    ),
  ]
  let assert Error(_errors) =
    scanner.validate_conventions(
      message_modules: modules,
      server_src: dir,
      shared_state_path: server_dir <> "/shared_state.gleam",
      app_error_path: server_dir <> "/app_error.gleam",
    )
  // app_error.gleam should have been scaffolded
  let assert Ok(content) = simplifile.read(server_dir <> "/app_error.gleam")
  let assert True = string.contains(content, "pub type AppError")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([dir])
}

pub fn validate_missing_handler_test() {
  let modules = [
    scanner.MessageModule(
      module_path: "core/messages",
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
      shared_state_path: "/tmp/nonexistent_server_src/server/shared_state.gleam",
      app_error_path: "/tmp/nonexistent_server_src/server/app_error.gleam",
    )
  let assert True =
    list.any(errors, fn(e) {
      case e {
        gen_error.MissingHandler(_, _) -> True
        _ -> False
      }
    })
}

pub fn validate_msg_from_server_single_field_passes_test() {
  let assert Ok(#(modules, _module_files)) =
    scanner.scan_message_modules(shared_src: "examples/todos/src/core")
  let assert Ok(Nil) =
    scanner.validate_msg_from_server_fields(message_modules: modules)
}

pub fn validate_msg_from_server_multi_field_fails_test() {
  // Write a temporary module with a multi-field MsgFromServer variant
  let dir = "build/.test_field_check"
  let _ = simplifile.create_directory_all(dir)
  let path = dir <> "/bad.gleam"
  let assert Ok(Nil) =
    simplifile.write(
      path,
      "pub type MsgFromServer {
  Good(String)
  Bad(Int, String)
}
",
    )
  let modules = [
    scanner.MessageModule(
      module_path: "test/bad",
      file_path: path,
      has_msg_from_client: False,
      has_msg_from_server: True,
      handler_modules: [],
    ),
  ]
  let assert Error(errors) =
    scanner.validate_msg_from_server_fields(message_modules: modules)
  let assert True =
    list.any(errors, fn(e) {
      case e {
        gen_error.MsgFromServerFieldCount(_, "Bad", 2) -> True
        _ -> False
      }
    })
  // Good variant should not be flagged
  let assert False =
    list.any(errors, fn(e) {
      case e {
        gen_error.MsgFromServerFieldCount(_, "Good", _) -> True
        _ -> False
      }
    })
  let assert Ok(Nil) = simplifile.delete_all([dir])
}

pub fn validate_msg_from_server_zero_field_passes_test() {
  let dir = "build/.test_field_check_zero"
  let _ = simplifile.create_directory_all(dir)
  let path = dir <> "/bare.gleam"
  let assert Ok(Nil) =
    simplifile.write(
      path,
      "pub type MsgFromServer {
  Acknowledged
}
",
    )
  let modules = [
    scanner.MessageModule(
      module_path: "test/bare",
      file_path: path,
      has_msg_from_client: False,
      has_msg_from_server: True,
      handler_modules: [],
    ),
  ]
  let assert Ok(Nil) =
    scanner.validate_msg_from_server_fields(message_modules: modules)
  let assert Ok(Nil) = simplifile.delete_all([dir])
}
