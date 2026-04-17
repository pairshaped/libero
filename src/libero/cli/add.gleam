//// `libero add` — scaffold a new client inside an existing Libero project.

import gleam/string
import libero/cli/templates
import simplifile

/// Add a client named `name` with the given `target` to the project at `path`.
///
/// Creates `<path>/src/clients/<name>/` and writes a starter app file only
/// when the directory contains no files yet. Appends the `[clients.<name>]`
/// section to `<path>/libero.toml` only when that section is absent.
pub fn add_client(
  project_path path: String,
  name name: String,
  target target: String,
) -> Result(Nil, String) {
  let client_dir = path <> "/src/clients/" <> name

  use _ <- map_err(simplifile.create_directory_all(client_dir))

  use existing <- map_err(simplifile.get_files(client_dir))

  use _ <- map_err(case existing {
    [] -> {
      let #(filename, content) = case target {
        "javascript" -> #("app.gleam", templates.starter_spa(name:))
        _ -> #("main.gleam", templates.starter_cli())
      }
      simplifile.write(client_dir <> "/" <> filename, content)
    }
    _ -> Ok(Nil)
  })

  use toml_content <- map_err(simplifile.read(path <> "/libero.toml"))

  let section_header = "[clients." <> name <> "]"
  case string.contains(toml_content, section_header) {
    True -> Ok(Nil)
    False -> {
      let addition =
        "\n[clients." <> name <> "]\ntarget = \"" <> target <> "\"\n"
      map_err(simplifile.append(path <> "/libero.toml", addition), fn(_) {
        Ok(Nil)
      })
    }
  }
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
