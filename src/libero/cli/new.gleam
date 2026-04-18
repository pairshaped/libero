//// `libero new` — scaffold a new Libero project at the given path.

import gleam/list
import gleam/result
import gleam/string
import libero/cli/templates
import simplifile

/// Scaffold a new project under `path`.
///
/// The project name is derived from the last segment of the path
/// (e.g. "tmp/test_app" → "test_app").
///
/// Creates the directory tree and writes starter source files so the
/// project compiles and runs out of the box.
pub fn scaffold(name _name: String, path path: String) -> Result(Nil, String) {
  let name =
    string.split(path, "/")
    |> list.last
    |> result.unwrap(path)

  // Abort if the project already exists
  case simplifile.is_file(path <> "/gleam.toml") {
    Ok(True) ->
      Error("project already exists at " <> path <> " (gleam.toml found)")
    _ -> {
      let core_dir = path <> "/src/core"
      scaffold_files(name:, path:, core_dir:)
    }
  }
}

fn scaffold_files(
  name name: String,
  path path: String,
  core_dir core_dir: String,
) -> Result(Nil, String) {
  use _ <- map_err(simplifile.create_directory_all(core_dir))
  // TODO: detect libero path from current project or use hex version once published
  let libero_path = "../libero"
  use _ <- map_err(simplifile.write(path <> "/gleam.toml", templates.gleam_toml(name:, libero_path:)))
  use _ <- map_err(simplifile.write(core_dir <> "/messages.gleam", templates.starter_messages()))
  use _ <- map_err(simplifile.write(core_dir <> "/handler.gleam", templates.starter_handler()))
  use _ <- map_err(simplifile.write(core_dir <> "/shared_state.gleam", templates.starter_shared_state()))
  use _ <- map_err(simplifile.write(core_dir <> "/app_error.gleam", templates.starter_app_error()))
  let test_dir = path <> "/test"
  use _ <- map_err(simplifile.create_directory_all(test_dir))
  use _ <- map_err(simplifile.write(test_dir <> "/" <> name <> "_test.gleam", templates.starter_test()))
  Ok(Nil)
}

fn map_err(
  result: Result(a, simplifile.FileError),
  next: fn(a) -> Result(Nil, String),
) -> Result(Nil, String) {
  case result {
    Ok(value) -> next(value)
    Error(err) -> Error(simplifile.describe_error(err))
  }
}
