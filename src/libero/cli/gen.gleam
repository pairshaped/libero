//// `libero gen`: TOML-driven codegen command.
////
//// Reads `gleam.toml` from the project path, scans the server source tree
//// for handler endpoint functions, and runs the full codegen pipeline for
//// each declared client.

import gleam/int
import gleam/io
import gleam/list
import gleam/result
import libero/codegen_decoders
import libero/codegen_dispatch
import libero/codegen_server
import libero/codegen_stubs
import libero/config
import libero/gen_error
import libero/scanner
import libero/toml_config
import libero/walker.{type DiscoveredType}
import simplifile

/// Run the `gen` command from the given project path (usually `"."`).
///
/// Reads `gleam.toml`, discovers handler endpoints in the server src dir,
/// and runs codegen for each declared client.
/// nolint: stringly_typed_error -- CLI module, String errors are user-facing messages
pub fn run(project_path project_path: String) -> Result(Nil, String) {
  // 1. Read gleam.toml
  use toml_content <- result.try(
    simplifile.read(project_path <> "/gleam.toml")
    |> result.map_error(fn(err) { "error: Cannot read gleam.toml
  \u{250c}\u{2500} gleam.toml
  \u{2502}
  \u{2502} " <> simplifile.describe_error(err) <> "
  \u{2502}
  hint: Run this command from your project root directory" }),
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

  // Scan for handler endpoints
  use endpoints <- result.try(
    scanner.scan_handler_endpoints(server_src:, shared_src:)
    |> result.map_error(fn(errors) {
      list.each(errors, gen_error.print_error)
      "endpoint scan failed"
    }),
  )

  use endpoints <- result.try(case endpoints {
    [] -> {
      gen_error.print_error(gen_error.NoEndpointsFound(server_src:))
      Error("no handler endpoints found")
    }
    _ -> Ok(endpoints)
  })

  io.println(
    "libero: found "
    <> int.to_string(list.length(endpoints))
    <> " handler endpoint(s) in "
    <> toml_cfg.server_src_dir,
  )

  // The wire envelope is a stable string both ends agree on; it has no
  // semantic meaning beyond routing. A constant keeps it predictable and
  // legible in error messages and wire logs.
  let wire_module_tag = "rpc"

  // Walk shared types for atom registration and decoder generation
  use discovered <- result.try(
    walker.walk_shared_types(shared_src: shared_src)
    |> result.map_error(fn(errors) {
      list.each(errors, gen_error.print_error)
      "type walk failed"
    }),
  )

  // Run codegen for each client
  use _ <- result.try(
    list.try_map(clients, fn(client) {
      run_client_codegen(
        project_path:,
        toml_cfg:,
        client:,
        endpoints:,
        wire_module_tag:,
        discovered:,
      )
    }),
  )

  // Generate server main entry point
  generate_main(project_path:, toml_cfg:, clients:)
}

// nolint: stringly_typed_error
fn generate_main(
  project_path project_path: String,
  toml_cfg toml_cfg: toml_config.TomlConfig,
  clients clients: List(toml_config.ClientConfig),
) -> Result(Nil, String) {
  let js_client_names =
    list.filter_map(clients, fn(c) {
      case c.target {
        "javascript" -> Ok(c.name)
        _ -> Error(Nil)
      }
    })
  use _ <- result.try(
    codegen_server.write_main(
      app_name: toml_cfg.name,
      port: toml_cfg.port,
      server_generated: project_path <> "/" <> toml_cfg.server_generated_dir,
      context_module: toml_cfg.context_module,
      js_client_names:,
      project_path:,
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
  endpoints endpoints: List(scanner.HandlerEndpoint),
  wire_module_tag wire_module_tag: String,
  discovered discovered: List(DiscoveredType),
) -> Result(Nil, String) {
  io.println("libero: generating stubs for client: " <> client.name)

  use raw_config <- result.try(toml_config.to_codegen_config(
    toml_cfg:,
    client: client.name,
    ws_path: "/ws",
  ))
  let config = config.prefix_paths(config: raw_config, project_path:)

  use _ <- result.try(
    simplifile.create_directory_all(config.server_generated)
    |> result.map_error(fn(err) {
      "cannot create "
      <> config.server_generated
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  use _ <- result.try(
    simplifile.create_directory_all(config.client_generated)
    |> result.map_error(fn(err) {
      "cannot create "
      <> config.client_generated
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )

  // Server dispatch
  use _ <- result.try(
    codegen_dispatch.write_endpoint_dispatch(
      endpoints:,
      server_generated: config.server_generated,
      atoms_module: config.atoms_module,
      context_module: toml_cfg.context_module,
      wire_module_tag:,
    )
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_endpoint_dispatch failed"
    }),
  )

  // Client stubs
  use _ <- result.try(
    codegen_stubs.write_endpoint_client_stubs(
      endpoints:,
      client_generated: config.client_generated,
      wire_module_tag:,
    )
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_endpoint_client_stubs failed"
    }),
  )

  // WebSocket handler
  use _ <- result.try(
    codegen_server.write_websocket(
      server_generated: config.server_generated,
      context_module: toml_cfg.context_module,
    )
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_websocket failed"
    }),
  )

  // Atom registration (server-side)
  use _ <- result.try(
    codegen_server.write_atoms(config:, discovered:)
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_atoms failed"
    }),
  )

  // Client-side
  use _ <- result.try(
    codegen_stubs.write_config(config:)
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_config failed"
    }),
  )
  use _ <- result.try(
    codegen_decoders.write_decoders_gleam(config:)
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_decoders_gleam failed"
    }),
  )
  use _ <- result.try(
    codegen_decoders.write_decoders_ffi(
      config:,
      discovered:,
      endpoints: endpoints,
    )
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_decoders_ffi failed"
    }),
  )
  use _ <- result.try(
    codegen_stubs.write_ssr_flags(client_generated: config.client_generated)
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_ssr_flags failed"
    }),
  )

  Ok(Nil)
}
