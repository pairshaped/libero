//// Snapshot tests for codegen_server output.

import birdie
import libero/codegen_server
import libero/config.{type Config, Config}
import libero/field_type
import libero/walker
import simplifile

fn base_config() -> Config {
  Config(
    ws_path: "/ws",
    atoms_output: "build/.test_server_snap/src/atoms.erl",
    atoms_module: "test@generated@rpc_atoms",
    config_output: "build/.test_server_snap/src/rpc_config.gleam",
    register_relpath_prefix: "../../",
    decoders_ffi_output: "build/.test_server_snap/src/ffi.mjs",
    decoders_gleam_output: "build/.test_server_snap/src/decoders.gleam",
    decoders_prelude_import_path: "../../libero/libero/decoders_prelude.mjs",
    server_generated: "build/.test_server_snap/src",
    client_generated: "build/.test_server_snap/src",
  )
}

// -- write_websocket --

pub fn write_websocket_snapshot_test() {
  let dir = "build/.test_ws_snap"
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(Nil) =
    codegen_server.write_websocket(
      server_generated: dir,
      context_module: "handler_context",
    )
  let assert Ok(content) = simplifile.read(dir <> "/websocket.gleam")
  birdie.snap(content, title: "codegen server: websocket")
  let assert Ok(Nil) = simplifile.delete_all([dir])
}

// -- write_atoms --

pub fn write_atoms_snapshot_test() {
  let dir = "build/.test_atoms_snap"
  let cfg =
    Config(
      ..base_config(),
      atoms_module: "myapp@generated@rpc_atoms",
      atoms_output: dir <> "/myapp@generated@rpc_atoms.erl",
    )
  let discovered = [
    walker.DiscoveredType(
      module_path: "shared/types",
      type_name: "Status",
      type_params: [],
      variants: [
        walker.DiscoveredVariant(
          module_path: "shared/types",
          variant_name: "Active",
          atom_name: "active",
          float_field_indices: [],
          fields: [],
        ),
        walker.DiscoveredVariant(
          module_path: "shared/types",
          variant_name: "Pending",
          atom_name: "pending",
          float_field_indices: [],
          fields: [],
        ),
      ],
    ),
    walker.DiscoveredType(
      module_path: "shared/types",
      type_name: "Item",
      type_params: [],
      variants: [
        walker.DiscoveredVariant(
          module_path: "shared/types",
          variant_name: "Item",
          atom_name: "item",
          float_field_indices: [1],
          fields: [
            field_type.StringField,
            field_type.FloatField,
          ],
        ),
      ],
    ),
  ]
  let assert Ok(Nil) =
    codegen_server.write_atoms(config: cfg, discovered: discovered)
  let assert Ok(content) =
    simplifile.read(dir <> "/myapp@generated@rpc_atoms.erl")
  birdie.snap(content, title: "codegen server: atoms")
  let assert Ok(Nil) = simplifile.delete_all([dir])
}

// -- write_atoms with no discovered types --

pub fn write_atoms_empty_discovered_snapshot_test() {
  let dir = "build/.test_atoms_empty_snap"
  let cfg =
    Config(
      ..base_config(),
      atoms_module: "empty@generated@rpc_atoms",
      atoms_output: dir <> "/empty@generated@rpc_atoms.erl",
    )
  let assert Ok(Nil) = codegen_server.write_atoms(config: cfg, discovered: [])
  let assert Ok(content) =
    simplifile.read(dir <> "/empty@generated@rpc_atoms.erl")
  birdie.snap(content, title: "codegen server: atoms empty")
  let assert Ok(Nil) = simplifile.delete_all([dir])
}

// -- write_if_missing --

pub fn write_if_missing_writes_when_file_absent_test() {
  let dir = "build/.test_write_if_missing"
  let path = dir <> "/scaffold.gleam"
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(Nil) =
    codegen_server.write_if_missing(path: path, content: "pub fn f() { 1 }")
  let assert Ok(_) = simplifile.read(path)
  let assert Ok(Nil) = simplifile.delete_all([dir])
}

pub fn write_if_missing_skips_when_file_exists_test() {
  let dir = "build/.test_write_if_missing_exists"
  let path = dir <> "/scaffold.gleam"
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let original = "// original content"
  let assert Ok(Nil) = simplifile.write(path, original)
  let assert Ok(Nil) =
    codegen_server.write_if_missing(path: path, content: "pub fn f() { 1 }")
  let assert Ok(contents) = simplifile.read(path)
  let assert "// original content" = contents
  let assert Ok(Nil) = simplifile.delete_all([dir])
}

// -- write_main --

pub fn write_main_no_js_clients_snapshot_test() {
  let dir = "build/.test_main_snap"
  let project = dir <> "/project"
  let assert Ok(Nil) = simplifile.create_directory_all(project <> "/src")
  let assert Ok(Nil) =
    codegen_server.write_main(
      app_name: "my_app",
      port: 8080,
      server_generated: "src/generated",
      context_module: "handler_context",
      js_client_names: [],
      project_path: project,
    )
  let assert Ok(content) = simplifile.read(project <> "/src/my_app.gleam")
  birdie.snap(content, title: "codegen server: main no JS clients")
  let assert Ok(Nil) = simplifile.delete_all([dir])
}

pub fn write_main_with_js_client_snapshot_test() {
  let dir = "build/.test_main_client_snap"
  let project = dir <> "/project"
  let assert Ok(Nil) = simplifile.create_directory_all(project <> "/src")
  let assert Ok(Nil) =
    codegen_server.write_main(
      app_name: "my_app",
      port: 3000,
      server_generated: "src/generated",
      context_module: "handler_context",
      js_client_names: ["web", "admin"],
      project_path: project,
    )
  let assert Ok(content) = simplifile.read(project <> "/src/my_app.gleam")
  birdie.snap(content, title: "codegen server: main with JS clients")
  let assert Ok(Nil) = simplifile.delete_all([dir])
}
