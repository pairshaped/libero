//// CLI command router for the Libero framework.
////
//// Usage: gleam run -m libero -- <command> [args]
//// Commands: new, add, gen, build

import argv
import gleam/io
import gleam/option.{type Option, None, Some}

pub type Database {
  Postgres
  Sqlite
}

pub type Command {
  New(name: String, database: Option(Database))
  Add(name: String, target: String)
  Gen
  Build
  Unknown
}

/// Parse CLI arguments into a Command.
pub fn parse_command() -> Command {
  parse_args(argv.load().arguments)
}

/// Parse a list of argument strings into a Command.
/// Separated from parse_command so tests can call it without argv.
pub fn parse_args(args: List(String)) -> Command {
  case args {
    ["new", name, "--database", db, ..] ->
      case parse_database(db) {
        Ok(database) -> New(name:, database: Some(database))
        Error(Nil) -> {
          io.println_error(
            "error: --database must be pg or sqlite, got: " <> db,
          )
          Unknown
        }
      }
    ["new", _name, "--database"] -> {
      io.println_error("error: --database requires a value (pg or sqlite)")
      Unknown
    }
    ["new", name, ..] -> New(name:, database: None)
    ["add", name, "--target", target, ..] -> Add(name:, target:)
    ["add", _name, ..] -> {
      io.println_error("error: --target is required")
      io.println_error(
        "  Usage: gleam run -m libero -- add <name> --target <javascript|erlang>",
      )
      Unknown
    }
    ["gen", ..] -> Gen
    ["build", ..] -> Build
    _ -> Unknown
  }
}

fn parse_database(value: String) -> Result(Database, Nil) {
  case value {
    "pg" -> Ok(Postgres)
    "sqlite" -> Ok(Sqlite)
    _ -> Error(Nil)
  }
}
