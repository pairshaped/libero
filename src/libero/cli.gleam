//// CLI command router for the Libero framework.
////
//// Usage: gleam run -m libero -- <command> [args]
//// Commands: new, add, gen

import argv
import gleam/io

pub type Command {
  New(name: String)
  Add(name: String, target: String)
  Gen
  Unknown
}

/// Parse CLI arguments into a Command.
pub fn parse_command() -> Command {
  let args = argv.load().arguments
  case args {
    ["new", name, ..] -> New(name:)
    ["add", name, "--target", target, ..] -> Add(name:, target:)
    ["add", name, ..] -> {
      io.println_error("error: --target is required")
      io.println_error(
        "  Usage: gleam run -m libero -- add <name> --target <javascript|erlang>",
      )
      Add(name:, target: "")
    }
    ["gen", ..] -> Gen
    _ -> Unknown
  }
}
