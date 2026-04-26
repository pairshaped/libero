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
  New(name: String, database: Option(Database), web: Bool)
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
    ["new", name, ..rest] -> parse_new_options(name, rest, None, False)
    ["add", name, "--target", target, ..] ->
      case target {
        "javascript" | "erlang" -> Add(name:, target:)
        _ -> {
          io.println_error("error: Invalid target: `" <> target <> "`
  \u{2502}
  \u{2502} --target must be \"javascript\" or \"erlang\"
  \u{2502}
  hint: gleam run -m libero -- add " <> name <> " --target javascript")
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

fn parse_new_options(
  name: String,
  args: List(String),
  database: Option(Database),
  web: Bool,
) -> Command {
  case args {
    [] -> New(name:, database:, web:)
    ["--web", ..rest] -> parse_new_options(name, rest, database, True)
    ["--database", db, ..rest] ->
      case parse_database(db) {
        Ok(parsed) -> parse_new_options(name, rest, Some(parsed), web)
        Error(Nil) -> {
          io.println_error("error: Invalid database: `" <> db <> "`
  \u{2502}
  \u{2502} --database must be \"pg\" or \"sqlite\"
  \u{2502}
  hint: gleam run -m libero -- new my_app --database pg")
          Unknown
        }
      }
    ["--database"] -> {
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
    [_, ..rest] -> parse_new_options(name, rest, database, web)
  }
}

fn parse_database(value: String) -> Result(Database, Nil) {
  case value {
    "pg" -> Ok(Postgres)
    "sqlite" -> Ok(Sqlite)
    _ -> Error(Nil)
  }
}
