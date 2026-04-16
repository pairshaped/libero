//// Message-type code generator.
////
//// Scans the shared package source directory (configured via `--shared`)
//// for modules that export `MsgFromClient` or `MsgFromServer` custom types and
//// produces server dispatch, client send stubs, wire codec registration,
//// and atom pre-registration files. See the README for conventions and
//// usage.

import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import libero/codegen
import libero/config
import libero/gen_error
import libero/scanner
import libero/walker

// ---------- Entry point ----------

pub fn main() -> Nil {
  let Nil = trap_signals()
  let config = config.parse_config()

  // --shared is required. Libero scans shared message modules for
  // MsgFromClient/MsgFromServer types.
  case config.shared_src {
    option.Some(shared_src) -> {
      io.println("libero: scanning shared message modules at " <> shared_src)
      case run(config: config, shared_src: shared_src) {
        Ok(count) -> {
          io.println(
            "libero: done. processed "
            <> int.to_string(count)
            <> " message module(s)",
          )
          let _halt = halt(0)
        }
        Error(errors) -> {
          list.each(errors, gen_error.print_error)
          let count = int.to_string(list.length(errors))
          io.println_error("")
          io.println_error("libero: " <> count <> " error(s), no files generated")
          let _halt = halt(1)
        }
      }
    }
    option.None -> {
      io.println_error("error: --shared is required")
      io.println_error("")
      io.println_error("  Example:")
      io.println_error(
        "    gleam run -m libero -- --ws-path=/ws/admin --shared=../shared --server=.",
      )
      let _halt = halt(1)
    }
  }
}

/// Scan shared message modules, validate conventions, walk types, and
/// generate dispatch + client send stubs + register + atoms.
fn run(
  config config: config.Config,
  shared_src shared_src: String,
) -> Result(Int, List(gen_error.GenError)) {
  use #(message_modules, module_files) <- result.try(
    scanner.scan_message_modules(shared_src: shared_src),
  )
  io.println(
    "libero: found "
    <> int.to_string(list.length(message_modules))
    <> " message module(s)",
  )

  let server_src = option.unwrap(config.server_src, "src")
  use message_modules <- result.try(
    scanner.validate_conventions(
      message_modules: message_modules,
      server_src: server_src,
    ),
  )
  // Validate MsgFromServer variants have exactly one field (required
  // for dispatch envelope unwrap).
  use _ <- result.try(
    scanner.validate_msg_from_server_fields(message_modules:),
  )

  use discovered <- result.try(
    walker.walk_message_registry_types(
      message_modules: message_modules,
      module_files: module_files,
    ),
  )
  io.println(
    "libero: discovered "
    <> int.to_string(list.length(discovered))
    <> " type variant(s) for registration",
  )

  // Generate server dispatch module.
  use _ <- result.try(
    codegen.write_dispatch(
      message_modules: message_modules,
      server_generated: config.server_generated,
      atoms_module: config.atoms_module,
    )
    |> result.map_error(fn(e) { [e] }),
  )

  // Generate client send stubs.
  use _ <- result.try(
    codegen.write_send_functions(
      message_modules: message_modules,
      client_generated: config.client_generated,
    ),
  )

  // Generate server push wrappers.
  use _ <- result.try(
    codegen.write_push_wrappers(
      message_modules: message_modules,
      server_generated: config.server_generated,
    ),
  )

  // Generate server WebSocket handler.
  use _ <- result.try(
    codegen.write_websocket(
      server_generated: config.server_generated,
    )
    |> result.map_error(fn(e) { [e] }),
  )

  // Generate WebSocket config module.
  use _ <- result.try(
    codegen.write_config(config: config)
    |> result.map_error(fn(e) { [e] }),
  )

  // Generate client-side type registration (gleam + mjs).
  use _ <- result.try(
    codegen.write_register(config: config, discovered: discovered),
  )

  // Generate Erlang atom pre-registration module.
  use _ <- result.try(
    codegen.write_atoms(config: config, discovered: discovered)
    |> result.map_error(fn(e) { [e] }),
  )

  Ok(list.length(message_modules))
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "libero_ffi", "trap_signals")
fn trap_signals() -> Nil
