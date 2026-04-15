import gleam/string
import libero
import simplifile

pub fn dispatch_contains_state_threading_test() {
  let assert Ok(#(modules, _module_files)) =
    libero.scan_message_modules(
      shared_src: "examples/todos/shared/src/shared",
    )
  let output_dir = "build/.test_codegen_dispatch"
  let assert Ok(Nil) =
    libero.write_v3_dispatch(
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
  // Must import handler
  let assert True = string.contains(content, "import server/handlers/todos")
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
    libero.scan_message_modules(
      shared_src: "examples/todos/shared/src/shared",
    )
  let output_dir = "build/.test_codegen_send"
  let assert Ok(Nil) =
    libero.write_v3_send_functions(
      message_modules: modules,
      client_generated: output_dir,
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/todos.gleam")

  // Must import the shared type
  let assert True = string.contains(content, "import shared/todos.{type ToServer}")
  // Must reference the correct module path
  let assert True = string.contains(content, "module: \"shared/todos\"")
  // Must import rpc
  let assert True = string.contains(content, "import libero/rpc")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}
