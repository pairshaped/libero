import gleam/option
import gleam/string
import libero/codegen
import libero/scanner
import simplifile

pub fn dispatch_contains_state_threading_test() {
  // Build a module with handler_module set, matching the todos example
  let modules = [
    scanner.MessageModule(
      module_path: "shared/todos",
      file_path: "examples/todos/shared/src/shared/todos.gleam",
      has_msg_from_client: True,
      has_msg_from_server: True,
      handler_module: option.Some("server/store"),
    ),
  ]
  let output_dir = "build/.test_codegen_dispatch"
  let assert Ok(Nil) =
    codegen.write_dispatch(
      message_modules: modules,
      server_generated: output_dir,
      atoms_module: "server@generated@libero@rpc_atoms",
    )
  let assert Ok(content) =
    simplifile.read(output_dir <> "/dispatch.gleam")

  // Must return 3-tuple with SharedState
  let assert True =
    string.contains(content, "#(BitArray, Option(PanicInfo), SharedState)")
  // Must call ensure_atoms
  let assert True = string.contains(content, "ensure_atoms()")
  // Must import discovered handler module with alias
  let assert True =
    string.contains(content, "import server/store as server_store_handler")
  // Must use alias in dispatch call
  let assert True =
    string.contains(content, "server_store_handler.update_from_client")
  // Must thread state to dispatch
  let assert True = string.contains(content, "dispatch(state, fn()")
  // Must have atoms external
  let assert True =
    string.contains(content, "server@generated@libero@rpc_atoms")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}

pub fn send_function_contains_module_path_test() {
  let assert Ok(#(modules, _module_files)) =
    scanner.scan_message_modules(
      shared_src: "examples/todos/shared/src/shared",
    )
  let output_dir = "build/.test_codegen_send"
  let assert Ok(Nil) =
    codegen.write_send_functions(
      message_modules: modules,
      client_generated: output_dir,
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/todos.gleam")

  // Must import the shared type
  let assert True = string.contains(content, "import shared/todos.{type MsgFromClient}")
  // Must reference the correct module path
  let assert True = string.contains(content, "module: \"shared/todos\"")
  // Must import rpc
  let assert True = string.contains(content, "import libero/rpc")
  // Must import rpc_register for auto-registration
  let assert True =
    string.contains(content, "import client/generated/libero/rpc_register")
  // Must call register_all before send
  let assert True = string.contains(content, "rpc_register.register_all()")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}
