//// `libero gen` — TOML-driven codegen command.
////
//// Reads `gleam.toml` from the project path, scans `shared/src/shared/` for
//// message modules, validates conventions, and runs the full codegen pipeline
//// for each declared client.

import gleam/dict
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
/// Reads `gleam.toml`, discovers message modules under `shared/src/shared/`, validates
/// conventions, and runs codegen for each declared client.
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

  // 4. Scan shared src dir for message modules
  //    If MsgFromClient/MsgFromServer types exist, use the classic convention.
  //    If the scan yields a NoMessageModules error (no MsgFromClient/MsgFromServer
  //    types found), fall through to the handler-as-contract convention.
  //    Other errors (e.g. CannotReadDir from a misconfigured shared_src_dir)
  //    are reported instead of being silently swallowed.
  case scanner.scan_message_modules(shared_src: shared_src) {
    Ok(#(message_modules, module_files)) ->
      run_classic_convention(
        project_path:,
        toml_cfg:,
        clients:,
        server_src:,
        message_modules:,
        module_files:,
      )
    Error(errors) ->
      case is_no_message_modules_only(errors) {
        True ->
          run_endpoint_convention(
            project_path:,
            toml_cfg:,
            clients:,
            server_src:,
            shared_src:,
          )
        False -> {
          list.each(errors, gen_error.print_error)
          Error("scan_message_modules failed")
        }
      }
  }
}

/// True if the only error from scanning is `NoMessageModules`. Anything else
/// (e.g. `CannotReadDir`, `ParseFailed`) is a real failure we need to surface
/// rather than treat as an implicit signal to switch conventions.
fn is_no_message_modules_only(errors: List(gen_error.GenError)) -> Bool {
  list.all(errors, fn(err) {
    case err {
      gen_error.NoMessageModules(_) -> True
      _ -> False
    }
  })
}

// nolint: stringly_typed_error
fn run_classic_convention(
  project_path project_path: String,
  toml_cfg toml_cfg: toml_config.TomlConfig,
  clients clients: List(toml_config.ClientConfig),
  server_src server_src: String,
  message_modules message_modules: List(scanner.MessageModule),
  module_files module_files: dict.Dict(String, String),
) -> Result(Nil, String) {
  io.println(
    "libero: found "
    <> int.to_string(list.length(message_modules))
    <> " message module(s) in "
    <> toml_cfg.shared_src_dir,
  )

  // Validate conventions
  let context_path = server_src <> "/" <> toml_cfg.context_module <> ".gleam"

  use message_modules <- result.try(
    scanner.validate_conventions(
      message_modules: message_modules,
      server_src: server_src,
      context_path: context_path,
    )
    |> result.map_error(fn(errors) {
      list.each(errors, gen_error.print_error)
      "convention validation failed"
    }),
  )

  // Validate MsgFromServer fields
  use _ <- result.try(
    scanner.validate_msg_from_server_fields(message_modules: message_modules)
    |> result.map_error(fn(errors) {
      list.each(errors, gen_error.print_error)
      "MsgFromServer field validation failed"
    }),
  )

  use _ <- result.try(codegen.check_segment_collisions(message_modules:))

  // Walk types
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

  // Run codegen for each client
  use _ <- result.try(
    list.try_map(clients, fn(client) {
      run_client_codegen(
        project_path:,
        toml_cfg:,
        client:,
        message_modules:,
        discovered:,
      )
    }),
  )

  // Generate server main entry point
  generate_main(project_path:, toml_cfg:, clients:)
}

// nolint: stringly_typed_error
fn run_endpoint_convention(
  project_path project_path: String,
  toml_cfg toml_cfg: toml_config.TomlConfig,
  clients clients: List(toml_config.ClientConfig),
  server_src server_src: String,
  shared_src shared_src: String,
) -> Result(Nil, String) {
  // Scan for handler endpoints (per-function convention)
  use endpoints <- result.try(
    scanner.scan_handler_endpoints(server_src:, shared_src:)
    |> result.map_error(fn(errors) {
      list.each(errors, gen_error.print_error)
      "endpoint scan failed"
    }),
  )

  io.println(
    "libero: found "
    <> int.to_string(list.length(endpoints))
    <> " handler endpoint(s) in "
    <> toml_cfg.server_src_dir,
  )

  // Determine shared module path from the shared_src dir
  let shared_module_path =
    scanner.scan_shared_module_path(shared_src: shared_src)
    |> result.unwrap("shared/messages")

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
      run_endpoint_client_codegen(
        project_path:,
        toml_cfg:,
        client:,
        endpoints:,
        shared_module_path:,
        discovered:,
      )
    }),
  )

  // Generate server main entry point
  generate_main(project_path:, toml_cfg:, clients:)
}

// nolint: stringly_typed_error
fn generate_main(
  project_path _project_path: String,
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
    codegen.write_main(
      app_name: toml_cfg.name,
      port: toml_cfg.port,
      server_generated: toml_cfg.server_generated_dir,
      context_module: toml_cfg.context_module,
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
fn run_endpoint_client_codegen(
  project_path project_path: String,
  toml_cfg toml_cfg: toml_config.TomlConfig,
  client client: toml_config.ClientConfig,
  endpoints endpoints: List(scanner.HandlerEndpoint),
  shared_module_path shared_module_path: String,
  discovered discovered: List(DiscoveredType),
) -> Result(Nil, String) {
  io.println("libero: generating stubs for client: " <> client.name)

  use config <- result.try(toml_config.to_codegen_config(
    toml_cfg:,
    client: client.name,
    ws_path: "/ws",
  ))

  let server_generated = project_path <> "/" <> config.server_generated
  let client_generated = project_path <> "/" <> config.client_generated

  use _ <- result.try(
    simplifile.create_directory_all(server_generated)
    |> result.map_error(fn(err) {
      "cannot create "
      <> server_generated
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  use _ <- result.try(
    simplifile.create_directory_all(client_generated)
    |> result.map_error(fn(err) {
      "cannot create "
      <> client_generated
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )

  // Server dispatch
  use _ <- result.try(
    codegen.write_endpoint_dispatch(
      endpoints:,
      server_generated: config.server_generated,
      atoms_module: config.atoms_module,
      context_module: toml_cfg.context_module,
      shared_module_path:,
    )
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_endpoint_dispatch failed"
    }),
  )

  // Client stubs
  use _ <- result.try(
    codegen.write_endpoint_client_stubs(
      endpoints:,
      client_generated: config.client_generated,
      shared_module_path:,
    )
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_endpoint_client_stubs failed"
    }),
  )

  // WebSocket handler (server-side, convention-independent)
  use _ <- result.try(
    codegen.write_websocket(
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
    codegen.write_atoms(config:, discovered:)
    |> result.map_error(fn(err) {
      gen_error.print_error(err)
      "write_atoms failed"
    }),
  )

  // Client-side (convention-independent)
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
    codegen.write_decoders_ffi(config:, discovered:, endpoints: endpoints)
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

// nolint: stringly_typed_error
fn run_client_codegen(
  project_path project_path: String,
  toml_cfg toml_cfg: toml_config.TomlConfig,
  client client: toml_config.ClientConfig,
  message_modules message_modules: List(scanner.MessageModule),
  discovered discovered: List(DiscoveredType),
) -> Result(Nil, String) {
  let endpoints = []
  io.println("libero: generating stubs for client: " <> client.name)

  // Convert TomlConfig to codegen Config for this client
  use config <- result.try(toml_config.to_codegen_config(
    toml_cfg:,
    client: client.name,
    ws_path: "/ws",
  ))

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
      context_module: toml_cfg.context_module,
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
      context_module: toml_cfg.context_module,
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
    codegen.write_decoders_ffi(config:, discovered:, endpoints: endpoints)
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
