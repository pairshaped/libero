//// CLI command router for the Libero framework.

import argv
import gleam/io

pub type Command {
  New(name: String)
  Add(name: String, target: String)
  Gen
  Dev
  Build
  Legacy
}

/// Parse CLI arguments into a Command.
pub fn parse_command() -> Command {
  let args = argv.load().arguments
  case args {
    ["new", name, ..] -> New(name:)
    ["add", name, "--target", target, ..] -> Add(name:, target:)
    ["add", name, ..] -> {
      io.println_error("error: --target is required")
      io.println_error("  Usage: libero add <name> --target <javascript|erlang>")
      Add(name:, target: "")
    }
    ["gen", ..] -> Gen
    ["dev", ..] -> Dev
    ["build", ..] -> Build
    _ -> Legacy
  }
}
