//// `config.prefix_paths` prepends a project root to every output
//// path in a `Config`. `cli/gen` uses it so codegen writes files
//// inside the caller's `project_path` instead of CWD when the two
//// differ. See bean libero-j18s.

import libero/config

pub fn prefix_paths_prefixes_server_generated_test() {
  let prefixed =
    config.prefix_paths(config: base_config(), project_path: "build/.test_proj")
  let assert "build/.test_proj/src/generated" = prefixed.server_generated
}

pub fn prefix_paths_prefixes_client_generated_test() {
  let prefixed =
    config.prefix_paths(config: base_config(), project_path: "build/.test_proj")
  let assert "build/.test_proj/clients/web/src/generated" =
    prefixed.client_generated
}

pub fn prefix_paths_prefixes_atoms_output_test() {
  let prefixed =
    config.prefix_paths(config: base_config(), project_path: "build/.test_proj")
  let assert "build/.test_proj/src/myapp@generated@rpc_atoms.erl" =
    prefixed.atoms_output
}

pub fn prefix_paths_prefixes_config_output_test() {
  let prefixed =
    config.prefix_paths(config: base_config(), project_path: "build/.test_proj")
  let assert "build/.test_proj/clients/web/src/generated/rpc_config.gleam" =
    prefixed.config_output
}

pub fn prefix_paths_prefixes_decoder_outputs_test() {
  let prefixed =
    config.prefix_paths(config: base_config(), project_path: "build/.test_proj")
  let assert "build/.test_proj/clients/web/src/generated/rpc_decoders_ffi.mjs" =
    prefixed.decoders_ffi_output
  let assert "build/.test_proj/clients/web/src/generated/rpc_decoders.gleam" =
    prefixed.decoders_gleam_output
}

pub fn prefix_paths_leaves_atoms_module_unchanged_test() {
  // atoms_module is an Erlang module name (with @ separators), not a
  // file path. Prefixing it would produce a meaningless module reference.
  let prefixed =
    config.prefix_paths(config: base_config(), project_path: "build/.test_proj")
  let assert "myapp@generated@rpc_atoms" = prefixed.atoms_module
}

pub fn prefix_paths_with_dot_is_identity_for_paths_test() {
  // project_path = "." (the CLI default) must produce a config whose
  // paths still resolve to the right files when read by simplifile.
  // Standardize on the literal "./..." form so tests can compare exactly.
  let prefixed = config.prefix_paths(config: base_config(), project_path: ".")
  let assert "./src/generated" = prefixed.server_generated
  let assert "./clients/web/src/generated" = prefixed.client_generated
}

fn base_config() -> config.Config {
  config.Config(
    ws_mode: config.WsPathOnly(path: "/ws"),
    atoms_output: "src/myapp@generated@rpc_atoms.erl",
    atoms_module: "myapp@generated@rpc_atoms",
    config_output: "clients/web/src/generated/rpc_config.gleam",
    register_relpath_prefix: "../../",
    decoders_ffi_output: "clients/web/src/generated/rpc_decoders_ffi.mjs",
    decoders_gleam_output: "clients/web/src/generated/rpc_decoders.gleam",
    decoders_prelude_import_path: "../../libero/libero/decoders_prelude.mjs",
    server_generated: "src/generated",
    client_generated: "clients/web/src/generated",
  )
}
