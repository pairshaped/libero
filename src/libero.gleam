//// Libero v4 framework CLI.
////
//// Libero-specific commands: new, add, gen
//// Everything else proxies to gleam verbatim.

import gleam/io
import libero/cli
import libero/cli/add as cli_add
import libero/cli/gen as cli_gen
import libero/cli/new as cli_new

pub fn main() -> Nil {
  let Nil = trap_signals()
  case cli.parse_command() {
    cli.New(name:) -> {
      case cli_new.scaffold(name:, path: name) {
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
    cli.Forward(args:) -> {
      io.println("Not a libero command, forwarding to gleam...")
      let exit_code = run_gleam(args)
      let _halt = halt(exit_code)
      Nil
    }
  }
}

/// Proxy a command to gleam, passing args verbatim. Returns exit code.
fn run_gleam(args: List(String)) -> Int {
  ffi_run_command("gleam", args)
}

@external(erlang, "libero_cli_ffi", "run_command")
fn ffi_run_command(command: String, args: List(String)) -> Int

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "libero_ffi", "trap_signals")
fn trap_signals() -> Nil
