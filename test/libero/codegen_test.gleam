import gleam/option
import gleam/string
import libero/codegen
import libero/config
import libero/scanner
import libero/walker
import simplifile

pub fn dispatch_contains_state_threading_test() {
  // Build a module with handler_module set, matching the todos example
  let modules = [
    scanner.MessageModule(
      module_path: "core/messages",
      file_path: "examples/todos/src/core/messages.gleam",
      has_msg_from_client: True,
      has_msg_from_server: True,
      handler_modules: ["core/handler"],
    ),
  ]
  let output_dir = "build/.test_codegen_dispatch"
  let assert Ok(Nil) =
    codegen.write_dispatch(
      message_modules: modules,
      server_generated: output_dir,
      atoms_module: "server@generated@libero@rpc_atoms",
      shared_state_module: "core/shared_state",
      app_error_module: "core/app_error",
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/dispatch.gleam")

  // Must return 3-tuple with SharedState
  let assert True =
    string.contains(content, "#(BitArray, Option(PanicInfo), SharedState)")
  // Must call ensure_atoms
  let assert True = string.contains(content, "ensure_atoms()")
  // Must import discovered handler module with alias
  let assert True =
    string.contains(content, "import core/handler as core_handler_handler")
  // Must use alias in dispatch call
  let assert True =
    string.contains(content, "core_handler_handler.update_from_client")
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
    scanner.scan_message_modules(shared_src: "examples/todos/src/core")
  let output_dir = "build/.test_codegen_send"
  let assert Ok(Nil) =
    codegen.write_send_functions(
      message_modules: modules,
      client_generated: output_dir,
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/messages.gleam")

  // Must import the shared type
  let assert True =
    string.contains(content, "import core/messages.{type MsgFromClient}")
  // Must reference the correct module path
  let assert True = string.contains(content, "module: \"core/messages\"")
  // Must import rpc
  let assert True = string.contains(content, "import libero/rpc")
  // Must import rpc_decoders so the typed decoder FFI side-effect runs on load
  let assert True = string.contains(content, "rpc_decoders")
  // Must reference decode_msg_from_server to prevent import stripping
  let assert True =
    string.contains(content, "rpc_decoders.decode_msg_from_server")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}

pub fn decoders_ffi_imports_stdlib_ctors_and_calls_setters_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: "examples/todos/src/core")
  let assert Ok(discovered) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let config =
    config.build_config(
      ws_mode: config.WsFullUrl(url: "ws://localhost:8080/ws"),
      namespace: option.None,
      client_root: "build/.test_decoders_ffi",
      shared_root: Ok("../shared"),
      server_root: Ok("."),
    )
  let assert Ok(Nil) =
    codegen.write_decoders_ffi(config: config, discovered: discovered)
  let assert Ok(content) =
    simplifile.read(
      "build/.test_decoders_ffi/src/client/generated/libero/rpc_decoders_ffi.mjs",
    )

  // Must import stdlib constructors
  let assert True = string.contains(content, "Ok, Error as ResultError")
  let assert True = string.contains(content, "Empty, NonEmpty")
  let assert True = string.contains(content, "gleam_stdlib/gleam.mjs")
  let assert True = string.contains(content, "Some, None")
  let assert True = string.contains(content, "gleam_stdlib/gleam/option.mjs")

  // Must import the three setters from decoders_prelude
  let assert True = string.contains(content, "setResultCtors")
  let assert True = string.contains(content, "setOptionCtors")
  let assert True = string.contains(content, "setListCtors")

  // Must call setters at module load time
  let assert True = string.contains(content, "setResultCtors(Ok, ResultError)")
  let assert True = string.contains(content, "setOptionCtors(Some, None)")
  let assert True = string.contains(content, "setListCtors(Empty, NonEmpty)")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all(["build/.test_decoders_ffi"])
}
