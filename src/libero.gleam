//// Libero v4 framework CLI.
////
//// Routes `gleam run -m libero -- <command> [args]` to the appropriate
//// handler. Falls back to legacy v3 codegen when no known command is given.

import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import libero/cli
import libero/codegen
import libero/config
import libero/gen_error
import libero/scanner
import libero/walker

pub fn main() -> Nil {
  let Nil = trap_signals()
  case cli.parse_command() {
    cli.New(name:) -> {
      io.println("libero new " <> name <> " (not yet implemented)")
      Nil
    }
    cli.Add(name:, target:) -> {
      io.println("libero add " <> name <> " --target " <> target <> " (not yet implemented)")
      Nil
    }
    cli.Gen -> {
      io.println("libero gen (not yet implemented)")
      Nil
    }
    cli.Dev -> {
      io.println("libero dev (not yet implemented)")
      Nil
    }
    cli.Build -> {
      io.println("libero build (not yet implemented)")
      Nil
    }
    cli.Legacy -> legacy_main()
  }
}

/// Original v3 codegen entry point, preserved for backwards compatibility.
fn legacy_main() -> Nil {
  let config = config.parse_config()
  case config.shared_src {
    option.Some(shared_src) -> {
      io.println("libero: scanning shared message modules at " <> shared_src)
      case legacy_run(config: config, shared_src: shared_src) {
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
          io.println_error(
            "libero: " <> count <> " error(s), no files generated",
          )
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

fn legacy_run(
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
  use message_modules <- result.try(scanner.validate_conventions(
    message_modules: message_modules,
    server_src: server_src,
  ))
  use _ <- result.try(scanner.validate_msg_from_server_fields(message_modules:))

  use discovered <- result.try(walker.walk_message_registry_types(
    message_modules: message_modules,
    module_files: module_files,
  ))
  io.println(
    "libero: discovered "
    <> int.to_string(list.length(discovered))
    <> " type variant(s) for registration",
  )

  use _ <- result.try(
    codegen.write_dispatch(
      message_modules: message_modules,
      server_generated: config.server_generated,
      atoms_module: config.atoms_module,
    )
    |> result.map_error(fn(e) { [e] }),
  )
  use _ <- result.try(codegen.write_send_functions(
    message_modules: message_modules,
    client_generated: config.client_generated,
  ))
  use _ <- result.try(codegen.write_push_wrappers(
    message_modules: message_modules,
    server_generated: config.server_generated,
  ))
  use _ <- result.try(
    codegen.write_websocket(server_generated: config.server_generated)
    |> result.map_error(fn(e) { [e] }),
  )
  use _ <- result.try(
    codegen.write_config(config: config)
    |> result.map_error(fn(e) { [e] }),
  )
  use _ <- result.try(codegen.write_register(
    config: config,
    discovered: discovered,
  ))
  use _ <- result.try(
    codegen.write_atoms(config: config, discovered: discovered)
    |> result.map_error(fn(e) { [e] }),
  )
  use _ <- result.try(
    codegen.write_ssr_flags(client_generated: config.client_generated)
    |> result.map_error(fn(e) { [e] }),
  )
  Ok(list.length(message_modules))
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "libero_ffi", "trap_signals")
fn trap_signals() -> Nil
