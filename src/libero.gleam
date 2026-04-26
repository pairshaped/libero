//// Libero — typed RPC framework for Gleam.
////
//// Usage: gleam run -m libero
////
//// Reads `gleam.toml` from the current directory and regenerates
//// dispatch, websocket, and client stubs based on handler signatures.

import gleam/io
import libero/cli/gen as cli_gen

pub fn main() -> Nil {
  let Nil = trap_signals()
  case cli_gen.run(project_path: ".") {
    Ok(Nil) -> Nil
    Error(msg) -> {
      io.println_error(msg)
      let _halt = halt(1)
      Nil
    }
  }
}

/// erlang:halt/1 never returns — it terminates the VM. The Nil return
/// type is a white lie required for type unification; code after
/// `let _halt = halt(1)` is dead but satisfies the type checker.
@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "libero_ffi", "trap_signals")
fn trap_signals() -> Nil
