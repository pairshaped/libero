//// `libero gen` — TOML-driven codegen command.
////
//// Reads `gleam.toml` from the project path, scans `src/core/` for message
//// modules, validates conventions, and runs the full codegen pipeline for
//// each declared client.

import gleam/int
import gleam/io
import gleam/list
import gleam/result
import libero/codegen
import libero/gen_error
import libero/scanner
import libero/toml_config
import libero/walker.{type DiscoveredType}
import simplifile

/// Run the `gen` command from the given project path (usually `"."`).
///
/// Reads `gleam.toml`, discovers message modules under `src/core/`, validates
/// conventions, and runs codegen for each declared client.
/// nolint: stringly_typed_error -- CLI module, String errors are user-facing messages
pub fn run(project_path project_path: String) -> Result(Nil, String) {
  // 1. Read gleam.toml
  use toml_content <- result.try(
    simplifile.read(project_path <> "/gleam.toml")
    |> result.map_error(fn(err) {
      "cannot read gleam.toml: " <> simplifile.describe_error(err)
    }),
  )

  // 2. Parse it
  use toml_cfg <- result.try(toml_config.parse(toml_content))

  // 3. If no clients declared, print and exit
  case toml_cfg.clients {
    [] -> {
      io.println("libero: no clients declared in gleam.toml")
      Ok(Nil)
    }
    clients -> run_with_clients(project_path:, toml_cfg:, clients:)
  }
}

// nolint: stringly_typed_error
fn run_with_clients(
  project_path project_path: String,
  toml_cfg toml_cfg: toml_config.TomlConfig,
  clients clients: List(toml_config.ClientConfig),
) -> Result(Nil, String) {
  let shared_src = project_path <> "/" <> toml_cfg.shared_src_dir
  let server_src = project_path <> "/" <> toml_cfg.server_src_dir

  // 4. Scan shared src dir for message modules
  use #(message_modules, module_files) <- result.try(
    scanner.scan_message_modules(shared_src: shared_src)
    |> result.map_error(fn(errors) {
      list.each(errors, gen_error.print_error)
      "scan failed"
    }),
  )

  io.println(
    "libero: found "
    <> int.to_string(list.length(message_modules))
    <> " message module(s) in "
    <> toml_cfg.shared_src_dir,
  )

  // 5. Validate conventions
  //
  // shared_state_module and app_error_module are Gleam module paths
  // (e.g., "server/shared_state"). The file they resolve to depends on
  // which package owns them - derive the file path from the module path
  // by using the server_src dir as the package root.
  let shared_state_path =
    server_src <> "/" <> toml_cfg.shared_state_module <> ".gleam"
  let app_error_path =
    server_src <> "/" <> toml_cfg.app_error_module <> ".gleam"

  use message_modules <- result.try(
    scanner.validate_conventions(
      message_modules: message_modules,
      server_src: server_src,
      shared_state_path: shared_state_path,
      app_error_path: app_error_path,
    )
    |> result.map_error(fn(errors) {
      list.each(errors, gen_error.print_error)
      "convention validation failed"
    }),
  )

  // 6. Validate MsgFromServer fields
  use _ <- result.try(
    scanner.validate_msg_from_server_fields(message_modules: message_modules)
    |> result.map_error(fn(errors) {
      list.each(errors, gen_error.print_error)
      "MsgFromServer field validation failed"
    }),
  )

  // 7. Walk types
  use discovered <- result.try(
    walker.walk_message_registry_types(
      message_modules: message_modules,
      module_files: module_files,
    )
    |> result.map_error(fn(errors) {
      list.each(errors, gen_error.print_error)
      "type walk failed"
    }),
  )

  // 8. Run codegen for each client
  use _ <- result.try(
    list.try_map(clients, fn(client) {
      run_client_codegen(
        project_path:,
        toml_cfg:,
        client:,
        message_modules:,
        discovered:,
      )
    })
    |> result.map_error(fn(msg) { msg }),
  )

  // 9. Generate server main entry point
  let js_client_names =
    list.filter_map(clients, fn(c) {
      case c.target {
        "javascript" -> Ok(c.name)
        _ -> Error(Nil)
      }
    })
  use _ <- result.try(
    codegen.write_main(
      app_name: toml_cfg.name,
      port: toml_cfg.port,
      server_generated: toml_cfg.server_generated_dir,
      shared_state_module: toml_cfg.shared_state_module,
      js_client_names:,
    )
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_main failed"
    }),
  )

  io.println("libero: done")
  Ok(Nil)
}

// nolint: stringly_typed_error
fn run_client_codegen(
  project_path project_path: String,
  toml_cfg toml_cfg: toml_config.TomlConfig,
  client client: toml_config.ClientConfig,
  message_modules message_modules: List(scanner.MessageModule),
  discovered discovered: List(DiscoveredType),
) -> Result(Nil, String) {
  io.println("libero: generating stubs for client: " <> client.name)

  // Convert TomlConfig to codegen Config for this client
  use config <- result.try(
    toml_config.to_codegen_config(toml_cfg:, client: client.name, ws_path: "/ws"),
  )

  // Ensure generated directories exist
  let server_generated = project_path <> "/" <> config.server_generated
  let client_generated = project_path <> "/" <> config.client_generated

  use _ <- result.try(
    simplifile.create_directory_all(server_generated)
    |> result.map_error(fn(err) {
      "cannot create directory "
      <> server_generated
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  use _ <- result.try(
    simplifile.create_directory_all(client_generated)
    |> result.map_error(fn(err) {
      "cannot create directory "
      <> client_generated
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )

  // Server-side (same for all clients, safe to overwrite)
  use _ <- result.try(
    codegen.write_dispatch(
      message_modules:,
      server_generated: config.server_generated,
      atoms_module: config.atoms_module,
      shared_state_module: toml_cfg.shared_state_module,
      app_error_module: toml_cfg.app_error_module,
    )
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_dispatch failed"
    }),
  )
  use _ <- result.try(
    codegen.write_push_wrappers(
      message_modules:,
      server_generated: config.server_generated,
    )
    |> result.map_error(fn(errors) {
      list.each(errors, gen_error.print_error)
      "write_push_wrappers failed"
    }),
  )
  use _ <- result.try(
    codegen.write_websocket(
      server_generated: config.server_generated,
      shared_state_module: toml_cfg.shared_state_module,
    )
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_websocket failed"
    }),
  )
  use _ <- result.try(
    codegen.write_atoms(config:, discovered:)
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_atoms failed"
    }),
  )

  // Clean up stale files from previous codegen versions
  delete_if_exists(config.client_generated <> "/rpc_register.gleam")
  delete_if_exists(config.client_generated <> "/rpc_register_ffi.mjs")

  // Client-side (unique per client)
  use _ <- result.try(
    codegen.write_send_functions(
      message_modules:,
      client_generated: config.client_generated,
    )
    |> result.map_error(fn(errors) {
      list.each(errors, gen_error.print_error)
      "write_send_functions failed"
    }),
  )
  use _ <- result.try(
    codegen.write_config(config:)
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_config failed"
    }),
  )
  use _ <- result.try(
    codegen.write_decoders_gleam(config:)
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_decoders_gleam failed"
    }),
  )
  use _ <- result.try(
    codegen.write_decoders_ffi(config:, discovered:)
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_decoders_ffi failed"
    }),
  )
  use _ <- result.try(
    codegen.write_ssr_flags(client_generated: config.client_generated)
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_ssr_flags failed"
    }),
  )

  Ok(Nil)
}

/// Best-effort delete — ignores errors (file may not exist).
fn delete_if_exists(path: String) -> Nil {
  simplifile.delete(path)
  |> result.unwrap(Nil)
}
