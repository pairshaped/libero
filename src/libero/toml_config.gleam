//// TOML configuration parser for Libero v4.
////
//// Parses a `libero.toml` string into a `TomlConfig` record.

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
  TomlConfig(name: String, port: Int, rest: Bool, clients: List(ClientConfig))
}

// ---------- Public API ----------

/// Parse a TOML string into a `TomlConfig`.
///
/// Returns `Error(String)` for parse failures or missing required fields.
pub fn parse(input: String) -> Result(TomlConfig, String) {
  use parsed <- result.try(
    tom.parse(input) |> result.map_error(fn(_) { "invalid TOML" }),
  )

  use name <- result.try(
    tom.get_string(parsed, ["name"])
    |> result.map_error(fn(_) { "missing required field: name" }),
  )

  let port =
    tom.get_int(parsed, ["port"]) |> result.unwrap(8080)

  let rest =
    tom.get_bool(parsed, ["server", "rest"]) |> result.unwrap(False)

  use clients <- result.try(parse_clients(parsed))

  Ok(TomlConfig(name: name, port: port, rest: rest, clients: clients))
}

/// Convert a `TomlConfig` and client name into the `Config` type used by
/// the codegen pipeline.
pub fn to_codegen_config(
  toml_cfg: TomlConfig,
  client client_name: String,
  ws_path ws_path: String,
) -> Result(Config, String) {
  use client <- result.try(
    list.find(toml_cfg.clients, fn(c) { c.name == client_name })
    |> result.map_error(fn(_) { "client not found: " <> client_name }),
  )
  let app = toml_cfg.name
  let client_generated = "src/clients/" <> client.name <> "/generated"
  let server_generated = "src/core/generated"
  let atoms_module = string.replace(app, each: "-", with: "_") <> "@generated@rpc_atoms"
  let atoms_output = "src/" <> atoms_module <> ".erl"
  let config_output = client_generated <> "/rpc_config.gleam"
  let register_gleam_output = client_generated <> "/rpc_register.gleam"
  let register_ffi_output = client_generated <> "/rpc_register_ffi.mjs"
  let register_relpath_prefix = "../../../../"
  let client_root = "src/clients/" <> client.name
  Ok(Config(
    ws_mode: WsPathOnly(path: ws_path),
    namespace: None,
    client_root: client_root,
    atoms_output: atoms_output,
    atoms_module: atoms_module,
    config_output: config_output,
    register_gleam_output: register_gleam_output,
    register_ffi_output: register_ffi_output,
    register_relpath_prefix: register_relpath_prefix,
    shared_src: Some("src/core"),
    server_src: Some("src"),
    server_generated: server_generated,
    client_generated: client_generated,
  ))
}

// ---------- Private helpers ----------

fn parse_clients(
  parsed: dict.Dict(String, tom.Toml),
) -> Result(List(ClientConfig), String) {
  case tom.get_table(parsed, ["clients"]) {
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
