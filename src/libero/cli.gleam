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
            "error: Invalid database: `"
            <> db
            <> "`
  \u{2502}
  \u{2502} --database must be \"pg\" or \"sqlite\"
  \u{2502}
  hint: gleam run -m libero -- new my_app --database pg",
          )
          Unknown
        }
      }
    ["new", _name, "--database"] -> {
      io.println_error(
        "error: Missing database value
  \u{2502}
  \u{2502} --database requires a value
  \u{2502}
  hint: gleam run -m libero -- new my_app --database pg
        gleam run -m libero -- new my_app --database sqlite",
      )
      Unknown
    }
    ["new", name, ..] -> New(name:, database: None)
    ["add", name, "--target", target, ..] ->
      case target {
        "javascript" | "erlang" -> Add(name:, target:)
        _ -> {
          io.println_error(
            "error: Invalid target: `"
            <> target
            <> "`
  \u{2502}
  \u{2502} --target must be \"javascript\" or \"erlang\"
  \u{2502}
  hint: gleam run -m libero -- add "
            <> name
            <> " --target javascript",
          )
          Unknown
        }
      }
    ["add", _name, ..] -> {
      io.println_error(
        "error: Missing --target flag
  \u{2502}
  \u{2502} The add command requires a target
  \u{2502}
  hint: gleam run -m libero -- add <name> --target javascript",
      )
      Unknown
    }
    ["gen", ..] -> Gen
    ["build", ..] -> Build
    ["new"] -> {
      io.println_error(
        "error: Missing project name
  \u{2502}
  \u{2502} The new command requires a project name
  \u{2502}
  hint: gleam run -m libero -- new my_app",
      )
      Unknown
    }
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
