//// TOML configuration parser for Libero v4.
////
//// Reads the `[libero]` section from gleam.toml.

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import libero/config.{type Config, Config, WsPathOnly}
import tom

// ---------- Types ----------

pub type ClientConfig {
  ClientConfig(name: String, target: String)
}

pub type TomlConfig {
  TomlConfig(
    name: String,
    port: Int,
    rest: Bool,
    clients: List(ClientConfig),
    /// Directory containing server source (where handler modules live).
    /// Default: "src" (package root).
    server_src_dir: String,
    /// Directory where libero writes server-side generated code
    /// (dispatch, websocket). Default: "src/server/generated".
    server_generated_dir: String,
    /// Path to the atoms .erl file. Default:
    /// "src/<name>@generated@rpc_atoms.erl".
    server_atoms_path: String,
    /// Directory containing shared source (where message modules live).
    /// Libero scans this directory for MsgFromClient/MsgFromServer types.
    /// Default: "shared/src/shared" - a separate target-agnostic package.
    /// Required for projects with both an Erlang server and a JS client:
    /// if messages lived in the server package, the JS client couldn't
    /// import them without pulling in wisp/sqlight (Erlang-only FFI).
    shared_src_dir: String,
    /// Gleam module path to the SharedState type used by libero dispatch.
    /// Default: "server/shared_state".
    shared_state_module: String,
    /// Gleam module path to the AppError type used by libero dispatch.
    /// Default: "server/app_error".
    app_error_module: String,
  )
}

// ---------- Public API ----------

/// Parse a TOML string into a `TomlConfig`.
///
/// Returns `Error(String)` for parse failures or missing required fields.
/// nolint: stringly_typed_error, error_context_lost -- config parsing; tom errors are opaque, string messages are more useful
pub fn parse(input: String) -> Result(TomlConfig, String) {
  use parsed <- result.try(
    tom.parse(input) |> result.map_error(fn(_) { "invalid TOML" }),
  )

  use name <- result.try(
    tom.get_string(parsed, ["name"])
    |> result.map_error(fn(_) { "missing required field: name" }),
  )

  let port =
    tom.get_int(parsed, ["libero", "port"]) |> result.unwrap(8080)

  let rest =
    tom.get_bool(parsed, ["libero", "server", "rest"]) |> result.unwrap(False)

  let server_src_dir =
    tom.get_string(parsed, ["libero", "server", "src_dir"])
    |> result.unwrap("src")

  let server_generated_dir =
    tom.get_string(parsed, ["libero", "server", "generated_dir"])
    |> result.unwrap("src/server/generated")

  let default_atoms =
    "src/"
    <> string.replace(name, each: "-", with: "_")
    <> "@generated@rpc_atoms.erl"
  let server_atoms_path =
    tom.get_string(parsed, ["libero", "server", "atoms_path"])
    |> result.unwrap(default_atoms)

  let shared_src_dir =
    tom.get_string(parsed, ["libero", "shared", "src_dir"])
    |> result.unwrap("shared/src/shared")

  let shared_state_module =
    tom.get_string(parsed, ["libero", "shared_state_module"])
    |> result.unwrap("server/shared_state")

  let app_error_module =
    tom.get_string(parsed, ["libero", "app_error_module"])
    |> result.unwrap("server/app_error")

  use clients <- result.try(parse_clients(parsed))

  Ok(TomlConfig(
    name: name,
    port: port,
    rest: rest,
    clients: clients,
    server_src_dir: server_src_dir,
    server_generated_dir: server_generated_dir,
    server_atoms_path: server_atoms_path,
    shared_src_dir: shared_src_dir,
    shared_state_module: shared_state_module,
    app_error_module: app_error_module,
  ))
}

/// Convert a `TomlConfig` and client name into the `Config` type used by
/// the codegen pipeline.
/// nolint: stringly_typed_error, error_context_lost
pub fn to_codegen_config(
  toml_cfg toml_cfg: TomlConfig,
  client client_name: String,
  ws_path ws_path: String,
) -> Result(Config, String) {
  use client <- result.try(
    list.find(toml_cfg.clients, fn(c) { c.name == client_name })
    |> result.map_error(fn(_) { "client not found: " <> client_name }),
  )
  let app = toml_cfg.name
  let client_generated = "clients/" <> client.name <> "/src/generated"
  let server_generated = toml_cfg.server_generated_dir
  let atoms_module = string.replace(app, each: "-", with: "_") <> "@generated@rpc_atoms"
  let atoms_output = toml_cfg.server_atoms_path
  let config_output = client_generated <> "/rpc_config.gleam"
  // The FFI file at `clients/<name>/src/generated/rpc_decoders_ffi.mjs` is
  // copied verbatim by gleam to `build/dev/javascript/<name>/generated/`.
  // From there, 2 levels up reaches `build/dev/javascript/` - the root where
  // other packages (libero, gleam_stdlib) live. Gleam only rewrites import
  // paths in .gleam-compiled .mjs files, not in literal .mjs FFI files.
  let register_relpath_prefix = "../../"
  let decoders_ffi_output = client_generated <> "/rpc_decoders_ffi.mjs"
  let decoders_gleam_output = client_generated <> "/rpc_decoders.gleam"
  let decoders_prelude_import_path =
    register_relpath_prefix <> "libero/libero/decoders_prelude.mjs"
  let client_root = "clients/" <> client.name
  Ok(Config(
    ws_mode: WsPathOnly(path: ws_path),
    namespace: None,
    client_root: client_root,
    atoms_output: atoms_output,
    atoms_module: atoms_module,
    config_output: config_output,
    register_relpath_prefix: register_relpath_prefix,
    decoders_ffi_output: decoders_ffi_output,
    decoders_gleam_output: decoders_gleam_output,
    decoders_prelude_import_path: decoders_prelude_import_path,
    shared_src: Some(toml_cfg.shared_src_dir),
    server_src: Some(toml_cfg.server_src_dir),
    server_generated: server_generated,
    client_generated: client_generated,
  ))
}

// ---------- Private helpers ----------

// nolint: stringly_typed_error, thrown_away_error, error_context_lost -- tom errors are opaque
fn parse_clients(
  parsed: dict.Dict(String, tom.Toml),
) -> Result(List(ClientConfig), String) {
  case tom.get_table(parsed, ["libero", "clients"]) {
    Error(_) -> Ok([])
    Ok(clients_dict) -> {
      let names = dict.keys(clients_dict)
      list.try_map(names, fn(name) {
        use client_table <- result.try(
          tom.get_table(clients_dict, [name])
          |> result.map_error(fn(_) {
            "invalid clients." <> name <> " section"
          }),
        )
        use target <- result.try(
          tom.get_string(client_table, ["target"])
          |> result.map_error(fn(_) {
            "missing target in clients." <> name
          }),
        )
        Ok(ClientConfig(name: name, target: target))
      })
    }
  }
}
