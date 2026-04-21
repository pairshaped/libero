//// `libero add` — scaffold a new client inside an existing Libero project.

import gleam/list
import gleam/result
import libero/cli/templates
import libero/toml_config
import simplifile

/// Add a client named `name` with the given `target` to the project at `path`.
///
/// Creates `<path>/clients/<name>/src/` and writes a starter app file only
/// when the src directory contains no files yet. Generates a `gleam.toml`
/// for the client package if missing. Appends the `[tools.libero.clients.<name>]`
/// section to the root `gleam.toml` only when that section is absent.
/// nolint: stringly_typed_error -- CLI module, String errors are user-facing messages
pub fn add_client(
  project_path path: String,
  name name: String,
  target target: String,
) -> Result(Nil, String) {
  let client_dir = path <> "/clients/" <> name
  let client_src = client_dir <> "/src"

  use _ <- map_err(simplifile.create_directory_all(client_src))

  // Generate client gleam.toml if missing
  let client_toml_path = client_dir <> "/gleam.toml"
  use root_name <- try_read_root_name(path)
  use _ <- write_if_missing(
    client_toml_path,
    templates.client_gleam_toml(name:, target:, root_package: root_name),
  )

  // Generate starter app if src is empty
  use existing <- map_err(simplifile.get_files(client_src))
  use _ <- map_err(case existing {
    [] -> {
      let #(filename, content) = case target {
        "javascript" -> #("app.gleam", templates.starter_spa(name:))
        _ -> #("main.gleam", templates.starter_cli())
      }
      simplifile.write(client_src <> "/" <> filename, content)
    }
    _ -> Ok(Nil)
  })

  // Append [tools.libero.clients.<name>] to root gleam.toml if missing
  use toml_content <- map_err(simplifile.read(path <> "/gleam.toml"))
  let already_declared = case toml_config.parse(toml_content) {
    Ok(cfg) -> list.any(cfg.clients, fn(c) { c.name == name })
    Error(_) -> False
    // nolint: thrown_away_error -- unparseable toml treated as "not declared"
  }
  case already_declared {
    True -> Ok(Nil)
    False -> {
      let addition =
        "\n[tools.libero.clients."
        <> name
        <> "]\ntarget = \""
        <> target
        <> "\"\n"
      use _ <- map_err(simplifile.append(path <> "/gleam.toml", addition))
      Ok(Nil)
    }
  }
}

// nolint: stringly_typed_error, thrown_away_error -- best-effort name lookup, errors fall back to "app"
fn try_read_root_name(
  path: String,
  next: fn(String) -> Result(Nil, String),
) -> Result(Nil, String) {
  case simplifile.read(path <> "/gleam.toml") {
    Error(_) -> next("app")
    Ok(content) ->
      case toml_config.parse(content) {
        Ok(cfg) -> next(cfg.name)
        Error(_) -> next("app")
      }
  }
}

// nolint: stringly_typed_error
fn write_if_missing(
  path: String,
  content: String,
  next: fn(Nil) -> Result(Nil, String),
) -> Result(Nil, String) {
  case simplifile.is_file(path) |> result.unwrap(False) {
    True -> next(Nil)
    False ->
      case simplifile.write(path, content) {
        Ok(Nil) -> next(Nil)
        Error(err) -> Error(simplifile.describe_error(err))
      }
  }
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
