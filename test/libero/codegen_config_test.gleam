//// Tests for generated rpc_config.gleam content.

import gleam/string
import libero/codegen_stubs
import libero/config.{type Config, Config}
import simplifile

fn make_config(ws_path: String, output_dir: String) -> Config {
  Config(
    ws_path: ws_path,
    atoms_output: output_dir <> "/atoms.erl",
    atoms_module: "test@generated@rpc_atoms",
    config_output: output_dir <> "/src/generated/rpc_config.gleam",
    register_relpath_prefix: "../../",
    decoders_ffi_output: output_dir <> "/src/generated/rpc_decoders_ffi.mjs",
    decoders_gleam_output: output_dir <> "/src/generated/rpc_decoders.gleam",
    decoders_prelude_import_path: "../../libero/libero/decoders_prelude.mjs",
    server_generated: output_dir <> "/src/generated",
    client_generated: output_dir <> "/src/generated",
  )
}

pub fn write_config_emits_resolver_test() {
  let output_dir = "build/.test_config_path_only"
  let cfg = make_config("/ws/admin", output_dir)
  let assert Ok(Nil) =
    simplifile.create_directory_all(output_dir <> "/src/generated")
  let assert Ok(Nil) = codegen_stubs.write_config(config: cfg)

  let assert Ok(content) =
    simplifile.read(output_dir <> "/src/generated/rpc_config.gleam")

  // Should reference the path
  let assert True = string.contains(content, "/ws/admin")
  // Should have the resolve function
  let assert True = string.contains(content, "resolve_ws_url")

  // FFI file should exist
  let assert Ok(ffi) =
    simplifile.read(output_dir <> "/src/generated/rpc_config_ffi.mjs")
  let assert True = string.contains(ffi, "resolveWsUrl")
  let assert True = string.contains(ffi, "location")

  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}
