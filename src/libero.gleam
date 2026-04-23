//// Libero v4 framework CLI.
////
//// Usage: gleam run -m libero -- <command> [args]
//// Commands: new, add, gen, build

import gleam/io
import libero/cli
import libero/cli/add as cli_add
import libero/cli/build as cli_build
import libero/cli/gen as cli_gen
import libero/cli/new as cli_new

pub fn main() -> Nil {
  let Nil = trap_signals()
  case cli.parse_command() {
    cli.New(name:, database:) -> {
      case cli_new.scaffold(name:, path: name, database:) {
        Ok(Nil) -> io.println("Created " <> name <> ". Happy hacking!")
        Error(reason) -> io.println_error("error: " <> reason)
      }
      Nil
    }
    cli.Add(name:, target:) -> {
      case cli_add.add_client(project_path: ".", name:, target:) {
        Ok(Nil) ->
          io.println("Added client " <> name <> " (target: " <> target <> ")")
        Error(reason) -> io.println_error("error: " <> reason)
      }
      Nil
    }
    cli.Gen -> {
      case cli_gen.run(project_path: ".") {
        Ok(Nil) -> Nil
        Error(msg) -> {
          io.println_error("error: " <> msg)
          let _halt = halt(1)
          Nil
        }
      }
    }
    cli.Build -> {
      case cli_build.run(project_path: ".") {
        Ok(Nil) -> Nil
        Error(msg) -> {
          io.println_error("error: " <> msg)
          let _halt = halt(1)
          Nil
        }
      }
    }
    cli.Unknown -> {
      io.println("Libero — typed RPC framework for Gleam")
      io.println("")
      io.println("Usage: gleam run -m libero -- <command>")
      io.println("")
      io.println("Commands:")
      io.println("  new <name> [--database pg|sqlite]  Create a new project")
      io.println("  add <name> --target <target>  Add a client")
      io.println("  gen                           Regenerate stubs")
      io.println(
        "  build                         Gen + build server + all clients",
      )
      Nil
    }
  }
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "libero_ffi", "trap_signals")
fn trap_signals() -> Nil
