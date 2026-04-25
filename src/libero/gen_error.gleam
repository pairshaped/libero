import glance
import gleam/io
import simplifile

pub type GenError {
  CannotReadDir(path: String, cause: simplifile.FileError)
  CannotReadFile(path: String, cause: simplifile.FileError)
  CannotWriteFile(path: String, cause: simplifile.FileError)
  ParseFailed(path: String, cause: glance.Error)
  UnresolvedTypeModule(module_path: String, type_name: String)
  TypeNotFound(module_path: String, type_name: String)
  TypeAliasNotSupported(module_path: String, type_name: String)
}

pub fn print_error(err: GenError) -> Nil {
  io.println_error(to_string(err))
}

pub fn to_string(err: GenError) -> String {
  case err {
    CannotReadDir(path, cause) -> "error: Cannot read directory
  \u{250c}\u{2500} " <> path <> "
  \u{2502}
  \u{2502} " <> format_file_error(cause)

    CannotReadFile(path, cause) -> "error: Cannot read file
  \u{250c}\u{2500} " <> path <> "
  \u{2502}
  \u{2502} " <> format_file_error(cause)

    CannotWriteFile(path, cause) -> "error: Cannot write file
  \u{250c}\u{2500} " <> path <> "
  \u{2502}
  \u{2502} " <> format_file_error(cause) <> "
  \u{2502}
  hint: Check that the directory exists and you have write permission"

    ParseFailed(path, _cause) -> "error: Failed to parse Gleam source
  \u{250c}\u{2500} " <> path <> "
  \u{2502}
  \u{2502} glance could not parse this file as valid Gleam
  \u{2502}
  hint: Run `gleam check` to see the full compiler error"

    UnresolvedTypeModule(module_path, type_name) ->
      "error: Unresolved type module
  \u{250c}\u{2500} " <> module_path <> "
  \u{2502}
  \u{2502} Type `" <> type_name <> "` could not be resolved to a file path
  \u{2502}
  hint: Ensure the module is a path dependency of the client package.
        Check that `" <> module_path <> "` appears in the shared/ directory
        or is listed as a dependency in gleam.toml"

    TypeNotFound(module_path, type_name) -> "error: Type not found
  \u{250c}\u{2500} " <> module_path <> ".gleam
  \u{2502}
  \u{2502} Type `" <> type_name <> "` was not found in this module
  \u{2502}
  hint: The type may be private (add `pub`) or the module path may be
        incorrect. Libero scans for custom types, not type aliases."

    TypeAliasNotSupported(module_path, type_name) ->
      "error: Type alias not supported
  \u{250c}\u{2500} " <> module_path <> "
  \u{2502}
  \u{2502} \"" <> type_name <> "\" is a type alias. Libero cannot walk type aliases
  \u{2502} transitively \u{2014} their underlying type won't be registered for decoding.
  \u{2502}
  hint: Reference the underlying custom type directly in your message fields"
  }
}

fn format_file_error(err: simplifile.FileError) -> String {
  simplifile.describe_error(err)
}
