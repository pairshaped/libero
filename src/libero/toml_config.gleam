//// TOML configuration parser for Libero.
////
//// Reads the `[tools.libero]` section from gleam.toml.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import libero/config.{type Config, Config}
import libero/gen_error
import tom

// ---------- Types ----------

pub type ClientConfig {
  ClientConfig(name: String, target: String)
}

pub type TomlConfig {
  TomlConfig(
    name: String,
    port: Int,
    clients: List(ClientConfig),
    /// Directory containing server source (where handler modules live).
    /// Default: "src" (package root).
    server_src_dir: String,
    /// Directory where libero writes server-side generated code
    /// (dispatch, websocket). Default: "src/generated" (relative to server package root).
    server_generated_dir: String,
    /// Path to the atoms .erl file. Default:
    /// "src/<name>@generated@rpc_atoms.erl".
    server_atoms_path: String,
    /// Directory containing shared source (types referenced by handler
    /// signatures). Libero walks every public type here so it can emit
    /// decoders for anything reachable from a handler's params or return
    /// type.
    /// Default: "../shared/src/shared" (relative to server package root) - a separate target-agnostic package.
    /// Required for projects with both an Erlang server and a JS client:
    /// if shared types lived in the server package, the JS client couldn't
    /// import them without pulling in wisp/sqlight (Erlang-only FFI).
    shared_src_dir: String,
    /// Gleam module path to the HandlerContext type used by libero dispatch.
    /// Default: "handler_context".
    context_module: String,
  )
}

// ---------- Public API ----------

/// Parse a TOML string into a `TomlConfig`.
///
/// Returns `Error(String)` for parse failures or missing required fields.
/// nolint: stringly_typed_error, error_context_lost -- config parsing; tom errors are opaque, string messages are more useful
pub fn parse(input: String) -> Result(TomlConfig, String) {
  use parsed <- result.try(
    tom.parse(input)
    |> result.map_error(fn(_) {
      toml_error(
        title: "Failed to parse gleam.toml",
        body_lines: ["The file contains invalid TOML syntax"],
        hint: Some("Run `gleam check` to validate your gleam.toml"),
      )
    }),
  )

  use name <- result.try(
    tom.get_string(parsed, ["name"])
    |> result.map_error(fn(_) {
      toml_error(
        title: "Missing required field",
        body_lines: ["The `name` field is required at the top level"],
        hint: Some("Add: name = \"my_app\""),
      )
    }),
  )

  // Reject legacy [libero] config (must be [tools.libero] since v4.1.1)
  use _ <- result.try(case tom.get_table(parsed, ["libero"]) {
    Ok(_) ->
      Error(toml_error(
        title: "Legacy config section",
        body_lines: [
          "Found [libero] section, but since v4.1.1 config must be",
          "under [tools.libero]",
        ],
        hint: Some(
          "Rename [libero] to [tools.libero]\n        Rename [libero.clients.*] to [tools.libero.clients.*]",
        ),
      ))
    // nolint: thrown_away_error -- tom error means no legacy section, which is fine
    Error(_) -> Ok(Nil)
  })

  let raw_port =
    tom.get_int(parsed, ["tools", "libero", "port"]) |> result.unwrap(8080)
  use port <- result.try(case raw_port >= 1 && raw_port <= 65_535 {
    True -> Ok(raw_port)
    False ->
      Error(toml_error(
        title: "Invalid port number",
        body_lines: [
          "port = "
          <> int.to_string(raw_port)
          <> " is out of range (must be 1\u{2013}65535)",
        ],
        hint: None,
      ))
  })

  let server_src_dir =
    tom.get_string(parsed, ["tools", "libero", "server", "src_dir"])
    |> result.unwrap("src")

  let server_generated_dir =
    tom.get_string(parsed, ["tools", "libero", "server", "generated_dir"])
    |> result.unwrap("src/generated")

  let default_atoms =
    "src/"
    <> string.replace(name, each: "-", with: "_")
    <> "@generated@rpc_atoms.erl"
  let server_atoms_path =
    tom.get_string(parsed, ["tools", "libero", "server", "atoms_path"])
    |> result.unwrap(default_atoms)

  let shared_src_dir =
    tom.get_string(parsed, ["tools", "libero", "shared", "src_dir"])
    |> result.unwrap("../shared/src/shared")

  let context_module =
    tom.get_string(parsed, ["tools", "libero", "context_module"])
    |> result.unwrap("handler_context")

  use clients <- result.try(parse_clients(parsed))

  Ok(TomlConfig(
    name: name,
    port: port,
    clients: clients,
    server_src_dir: server_src_dir,
    server_generated_dir: server_generated_dir,
    server_atoms_path: server_atoms_path,
    shared_src_dir: shared_src_dir,
    context_module: context_module,
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
    |> result.map_error(fn(_) {
      toml_error(
        title: "Client not found",
        body_lines: [
          "No client named `" <> client_name <> "` in [tools.libero.clients]",
        ],
        hint: Some(
          "Add it manually: create clients/"
          <> client_name
          <> "/gleam.toml with target = \"javascript\",\n        then add [tools.libero.clients."
          <> client_name
          <> "] with target = \"javascript\" to server/gleam.toml.",
        ),
      )
    }),
  )
  let app = toml_cfg.name
  let client_generated = "../clients/" <> client.name <> "/src/generated"
  let server_generated = toml_cfg.server_generated_dir
  let atoms_module =
    string.replace(app, each: "-", with: "_") <> "@generated@rpc_atoms"
  let atoms_output = toml_cfg.server_atoms_path
  let config_output = client_generated <> "/rpc_config.gleam"
  // The FFI file lands at build/dev/javascript/<name>/generated/ (Gleam copies
  // it verbatim from src/generated/). From there, 2 levels up reaches
  // build/dev/javascript/ - the root where other packages live. Gleam only
  // rewrites import paths in compiled .mjs files, not in literal FFI files.
  let register_relpath_prefix = "../../"
  let decoders_ffi_output = client_generated <> "/rpc_decoders_ffi.mjs"
  let decoders_gleam_output = client_generated <> "/rpc_decoders.gleam"
  let decoders_prelude_import_path =
    register_relpath_prefix <> "libero/libero/decoders_prelude.mjs"
  Ok(Config(
    ws_path: ws_path,
    atoms_output: atoms_output,
    atoms_module: atoms_module,
    config_output: config_output,
    register_relpath_prefix: register_relpath_prefix,
    decoders_ffi_output: decoders_ffi_output,
    decoders_gleam_output: decoders_gleam_output,
    decoders_prelude_import_path: decoders_prelude_import_path,
    server_generated: server_generated,
    client_generated: client_generated,
  ))
}

// ---------- Private helpers ----------

/// Format a parser error pointing at gleam.toml. Pre-fills the path so
/// every call site doesn't have to repeat it.
fn toml_error(
  title title: String,
  body_lines body_lines: List(String),
  hint hint: option.Option(String),
) -> String {
  gen_error.error_box(title:, path: "gleam.toml", body_lines:, hint:)
}

// nolint: stringly_typed_error, thrown_away_error, error_context_lost -- tom errors are opaque
fn parse_clients(
  parsed: dict.Dict(String, tom.Toml),
) -> Result(List(ClientConfig), String) {
  case tom.get_table(parsed, ["tools", "libero", "clients"]) {
    Error(_) -> Ok([])
    Ok(clients_dict) -> {
      let names = dict.keys(clients_dict) |> list.sort(string.compare)
      list.try_map(names, fn(name) {
        use client_table <- result.try(
          tom.get_table(clients_dict, [name])
          |> result.map_error(fn(_) {
            toml_error(
              title: "Invalid client config",
              body_lines: [
                "[tools.libero.clients." <> name <> "] is not a valid table",
              ],
              hint: None,
            )
          }),
        )
        use target <- result.try(
          tom.get_string(client_table, ["target"])
          |> result.map_error(fn(_) {
            toml_error(
              title: "Missing target",
              body_lines: [
                "[tools.libero.clients."
                <> name
                <> "] is missing the `target` field",
              ],
              hint: Some("Add: target = \"javascript\""),
            )
          }),
        )
        use _ <- result.try(case target {
          "javascript" -> Ok(Nil)
          other ->
            Error(toml_error(
              title: "Unsupported client target",
              body_lines: [
                "[tools.libero.clients."
                  <> name
                  <> "] has target = \""
                  <> other
                  <> "\"",
                "libero only supports `javascript` clients today",
              ],
              hint: Some("Set target = \"javascript\""),
            ))
        })
        Ok(ClientConfig(name: name, target: target))
      })
    }
  }
}
