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
      file_path: "test/fixtures/shared/src/shared/messages.gleam",
      has_msg_from_client: True,
      has_msg_from_server: True,
      handlers: [
        scanner.HandlerInfo(module_path: "core/handler", handled_variants: [
          "AddTodo",
          "RemoveTodo",
        ]),
      ],
    ),
  ]
  let output_dir = "build/.test_codegen_dispatch"
  let assert Ok(Nil) =
    codegen.write_dispatch(
      message_modules: modules,
      server_generated: output_dir,
      atoms_module: "server@generated@libero@rpc_atoms",
      context_module: "core/context",
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/dispatch.gleam")

  // Must return 3-tuple with HandlerContext
  let assert True =
    string.contains(content, "#(BitArray, Option(PanicInfo), HandlerContext)")
  // Must call ensure_atoms
  let assert True = string.contains(content, "ensure_atoms()")
  // Must import discovered handler module with alias
  let assert True =
    string.contains(content, "import core/handler as core_handler_handler")
  // Must use alias in dispatch call
  let assert True =
    string.contains(content, "core_handler_handler.update_from_client")
  // Must thread state and request_id to dispatch
  let assert True = string.contains(content, "dispatch(state, request_id, fn()")
  // Must have atoms external
  let assert True =
    string.contains(content, "server@generated@libero@rpc_atoms")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}

pub fn send_function_contains_module_path_test() {
  let assert Ok(#(modules, _module_files)) =
    scanner.scan_message_modules(shared_src: "test/fixtures/shared/src/shared")
  let output_dir = "build/.test_codegen_send"
  let assert Ok(Nil) =
    codegen.write_send_functions(
      message_modules: modules,
      client_generated: output_dir,
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/messages.gleam")

  // Must import the shared type
  let assert True =
    string.contains(content, "import shared/messages.{type MsgFromClient}")
  // Must reference the correct module path
  let assert True = string.contains(content, "module: \"shared/messages\"")
  // Must import rpc
  let assert True = string.contains(content, "import libero/rpc")
  // Must import rpc_decoders so the typed decoder FFI side-effect runs on load
  let assert True = string.contains(content, "rpc_decoders")
  // Must reference ensure_decoders to trigger FFI side-effect loading
  let assert True = string.contains(content, "rpc_decoders.ensure_decoders")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}

pub fn decoders_ffi_imports_stdlib_ctors_and_calls_setters_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: "test/fixtures/shared/src/shared")
  let assert Ok(discovered) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let assert Ok(config) =
    config.build_config(
      ws_mode: config.WsFullUrl(url: "ws://localhost:8080/ws"),
      namespace: option.None,
      client_root: "build/.test_decoders_ffi",
      shared_root: Ok("../shared"),
      server_root: Ok("."),
    )
  let assert Ok(Nil) =
    codegen.write_decoders_ffi(
      config: config,
      discovered: discovered,
      endpoints: [],
    )
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

  // Must import the setters from decoders_prelude
  let assert True = string.contains(content, "setResultCtors")
  let assert True = string.contains(content, "setOptionCtors")
  let assert True = string.contains(content, "setListCtors")
  let assert True = string.contains(content, "setDictFromList")

  // Must call setters at module load time
  let assert True = string.contains(content, "setResultCtors(Ok, ResultError)")
  let assert True = string.contains(content, "setOptionCtors(Some, None)")
  let assert True = string.contains(content, "setListCtors(Empty, NonEmpty)")
  let assert True = string.contains(content, "setDictFromList(dictFromList)")

  // Must import dict.from_list from stdlib
  let assert True = string.contains(content, "from_list as dictFromList")
  let assert True = string.contains(content, "gleam_stdlib/gleam/dict.mjs")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all(["build/.test_decoders_ffi"])
}

pub fn decoders_ffi_registers_float_fields_test() {
  let discovered = [
    walker.DiscoveredType(
      module_path: "shared/types",
      type_name: "WithFloats",
      type_params: [],
      variants: [
        walker.DiscoveredVariant(
          module_path: "shared/types",
          variant_name: "WithFloats",
          atom_name: "with_floats",
          float_field_indices: [0, 1],
          fields: [walker.FloatField, walker.FloatField, walker.StringField],
        ),
      ],
    ),
  ]
  let assert Ok(config) =
    config.build_config(
      ws_mode: config.WsFullUrl(url: "ws://localhost:8080/ws"),
      namespace: option.None,
      client_root: "build/.test_decoders_float_fields",
      shared_root: Ok("../shared"),
      server_root: Ok("."),
    )
  let assert Ok(Nil) =
    codegen.write_decoders_ffi(
      config: config,
      discovered: discovered,
      endpoints: [],
    )
  let assert Ok(content) =
    simplifile.read(
      "build/.test_decoders_float_fields/src/client/generated/libero/rpc_decoders_ffi.mjs",
    )

  let assert True = string.contains(content, "registerFloatFields")
  let assert True =
    string.contains(content, "registerFloatFields(\"with_floats\", [0, 1])")

  let assert Ok(Nil) =
    simplifile.delete_all(["build/.test_decoders_float_fields"])
}

/// Wire-shape mismatches must produce a typed `TransportFailure` variant,
/// not a `Failure(String)`. Generated stubs are typed as
/// `RemoteData(payload, DomainError)` — a String in the Failure slot would
/// crash exhaustive case-matches on the domain error in consumer code.
pub fn response_decoder_fallback_emits_transport_failure_test() {
  let endpoints = [
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "ping",
      params: [],
      return_type_str: "Result(Nil, Nil)",
    ),
  ]
  let assert Ok(config) =
    config.build_config(
      ws_mode: config.WsFullUrl(url: "ws://localhost:8080/ws"),
      namespace: option.None,
      client_root: "build/.test_decoders_response_fallback",
      shared_root: Ok("../shared"),
      server_root: Ok("."),
    )
  let assert Ok(Nil) =
    codegen.write_decoders_ffi(
      config: config,
      discovered: [],
      endpoints: endpoints,
    )
  let assert Ok(content) =
    simplifile.read(
      "build/.test_decoders_response_fallback/src/client/generated/libero/rpc_decoders_ffi.mjs",
    )

  // Fallback must construct TransportFailure, not Failure(String).
  let assert True =
    string.contains(content, "new _TransportFailure(\"RPC framework error\")")
  let assert False =
    string.contains(content, "new _Failure(\"RPC framework error\")")
  // TransportFailure must be imported from remote_data.
  let assert True =
    string.contains(content, "TransportFailure as _TransportFailure")

  let assert Ok(Nil) =
    simplifile.delete_all(["build/.test_decoders_response_fallback"])
}

pub fn response_decoder_handles_dict_of_custom_type_test() {
  let endpoints = [
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "echo_dict_string_item",
      params: [#("value", "Dict(String, types.Item)")],
      return_type_str: "Result(Dict(String, types.Item), Nil)",
    ),
  ]
  let assert Ok(config) =
    config.build_config(
      ws_mode: config.WsFullUrl(url: "ws://localhost:8080/ws"),
      namespace: option.None,
      client_root: "build/.test_decoders_response_dict",
      shared_root: Ok("../shared"),
      server_root: Ok("."),
    )
  let assert Ok(Nil) =
    codegen.write_decoders_ffi(
      config: config,
      discovered: [],
      endpoints: endpoints,
    )
  let assert Ok(content) =
    simplifile.read(
      "build/.test_decoders_response_dict/src/client/generated/libero/rpc_decoders_ffi.mjs",
    )

  let assert True =
    string.contains(
      content,
      "decode_dict_of((t0) => decode_string(t0), (t1) => decode_shared_types_item(t1), inner[1])",
    )
  let assert False = string.contains(content, "decode_shared_Dict")

  let assert Ok(Nil) =
    simplifile.delete_all(["build/.test_decoders_response_dict"])
}

pub fn write_if_missing_preserves_existing_file_test() {
  let dir = "build/.test_write_if_missing_preserve"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let path = dir <> "/app.gleam"
  let custom_content = "// custom entry point, do not overwrite"
  let assert Ok(Nil) = simplifile.write(path, custom_content)

  let assert Ok(Nil) =
    codegen.write_if_missing(path: path, content: "// generated content")

  let assert Ok(content) = simplifile.read(path)
  let assert True = content == custom_content

  let assert Ok(Nil) = simplifile.delete_all([dir])
}

pub fn write_if_missing_writes_when_file_absent_test() {
  let dir = "build/.test_write_if_missing_fresh"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let path = dir <> "/app.gleam"

  let assert Ok(Nil) =
    codegen.write_if_missing(path: path, content: "// generated content")

  let assert Ok(content) = simplifile.read(path)
  let assert True = string.contains(content, "// generated content")

  let assert Ok(Nil) = simplifile.delete_all([dir])
}
