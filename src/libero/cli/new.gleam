//// `libero new` — scaffold a new Libero project at the given path.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import libero/cli.{type Database}
import libero/cli/templates
import libero/cli/templates/db as db_templates
import libero/format
import simplifile

/// Scaffold a new project under `path`.
///
/// The project name is derived from the last segment of the path
/// (e.g. "tmp/test_app" → "test_app").
///
/// Creates the directory tree and writes starter source files so the
/// project compiles and runs out of the box.
/// nolint: stringly_typed_error -- CLI module, String errors are user-facing messages
pub fn scaffold(
  name _name: String,
  path path: String,
  database database: Option(Database),
) -> Result(Nil, String) {
  let name =
    string.split(path, "/")
    |> list.last
    |> result.unwrap(path)

  case validate_name(name) {
    Error(msg) -> Error(msg)
    Ok(Nil) -> scaffold_validated(name:, path:, database:)
  }
}

// nolint: stringly_typed_error
fn scaffold_validated(
  name name: String,
  path path: String,
  database database: Option(Database),
) -> Result(Nil, String) {
  // Abort if the project already exists
  case simplifile.is_file(path <> "/gleam.toml") {
    Ok(True) ->
      Error("project already exists at " <> path <> " (gleam.toml found)")
    _ -> {
      let server_dir = path <> "/src/server"
      scaffold_files(name:, path:, server_dir:, database:)
    }
  }
}

// nolint: stringly_typed_error
fn validate_name(name: String) -> Result(Nil, String) {
  case string.to_graphemes(name) {
    [] -> Error("project name cannot be empty")
    [first, ..rest] ->
      case is_lowercase_letter(first) {
        False ->
          Error(
            "project name must start with a lowercase letter, got: " <> name,
          )
        True ->
          case
            list.all(rest, fn(ch) {
              is_lowercase_letter(ch) || is_digit(ch) || ch == "_"
            })
          {
            False ->
              Error(
                "project name must contain only lowercase letters, digits, and underscores, got: "
                <> name,
              )
            True -> Ok(Nil)
          }
      }
  }
}

const lowercase_letters = "abcdefghijklmnopqrstuvwxyz"

const digits = "0123456789"

fn is_lowercase_letter(ch: String) -> Bool {
  string.contains(lowercase_letters, ch)
}

fn is_digit(ch: String) -> Bool {
  string.contains(digits, ch)
}

// nolint: stringly_typed_error
fn scaffold_files(
  name name: String,
  path path: String,
  server_dir server_dir: String,
  database database: Option(Database),
) -> Result(Nil, String) {
  // Compute database-specific template values
  let #(db_deps, extra_toml, db_readme) = case database {
    None -> #("", "", "")
    Some(db) -> #(
      db_templates.deps(db),
      db_templates.extra_toml(db),
      db_templates.readme_section(db),
    )
  }

  use _ <- map_err(simplifile.create_directory_all(server_dir))

  // Root (server) package
  use _ <- map_err(simplifile.write(
    path <> "/gleam.toml",
    templates.gleam_toml(name:, db_deps:, extra_toml:),
  ))
  use _ <- map_err(write_formatted(
    path: server_dir <> "/handler.gleam",
    content: templates.starter_handler(),
  ))
  use _ <- map_err(
    write_formatted(
      path: server_dir <> "/shared_state.gleam",
      content: case database {
        None -> templates.starter_shared_state()
        Some(db) -> db_templates.shared_state(db)
      },
    ),
  )
  use _ <- map_err(write_formatted(
    path: server_dir <> "/app_error.gleam",
    content: templates.starter_app_error(),
  ))

  // Write database files when --database is set
  use _ <-
    fn(next) {
      case database {
        None -> next(Nil)
        Some(db) -> {
          use _ <- map_err(write_formatted(
            path: server_dir <> "/db.gleam",
            content: db_templates.db_module(db),
          ))
          use _ <- map_err(simplifile.create_directory_all(server_dir <> "/sql"))
          next(Nil)
        }
      }
    }

  // Shared package - messages live here so JS clients can import them
  // without pulling in Erlang-only server dependencies.
  let shared_dir = path <> "/shared/src/shared"
  use _ <- map_err(simplifile.create_directory_all(shared_dir))
  use _ <- map_err(simplifile.write(
    path <> "/shared/gleam.toml",
    templates.shared_gleam_toml(),
  ))
  use _ <- map_err(write_formatted(
    path: shared_dir <> "/messages.gleam",
    content: templates.starter_messages(),
  ))

  let test_dir = path <> "/test"
  use _ <- map_err(simplifile.create_directory_all(test_dir))
  use _ <- map_err(write_formatted(
    path: test_dir <> "/" <> name <> "_test.gleam",
    content: templates.starter_test(),
  ))

  // README
  use _ <- map_err(simplifile.write(
    path <> "/README.md",
    templates.starter_readme(name:, db_section: db_readme),
  ))
  Ok(Nil)
}

/// Write a file, running `gleam format` on .gleam files first.
fn write_formatted(
  path path: String,
  content content: String,
) -> Result(Nil, simplifile.FileError) {
  let formatted = case string.ends_with(path, ".gleam") {
    True -> format.format_gleam(content)
    False -> content
  }
  simplifile.write(path, formatted)
}

// nolint: stringly_typed_error
fn map_err(
  result: Result(a, simplifile.FileError),
  next: fn(a) -> Result(Nil, String),
) -> Result(Nil, String) {
  case result {
    Ok(value) -> next(value)
    Error(err) -> Error(simplifile.describe_error(err))
  }
}
