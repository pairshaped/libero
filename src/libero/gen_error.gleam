import glance
import gleam/io
import simplifile

pub type GenError {
  CannotReadDir(path: String, cause: simplifile.FileError)
  CannotReadFile(path: String, cause: simplifile.FileError)
  CannotWriteFile(path: String, cause: simplifile.FileError)
  ParseFailed(path: String, cause: glance.Error)
  EmptyModulePath(path: String)
  UnresolvedTypeModule(module_path: String, type_name: String)
  TypeNotFound(module_path: String, type_name: String)
  MissingSharedState(expected_path: String)
  MissingAppError(expected_path: String)
  MissingHandler(message_module: String, expected_path: String)
  NoMessageModules(shared_path: String)
}

pub fn print_error(err: GenError) -> Nil {
  let message = case err {
    CannotReadDir(path, cause) ->
      "cannot read directory: "
      <> path
      <> " ("
      <> format_file_error(cause)
      <> ")"
    CannotReadFile(path, cause) ->
      "cannot read file: " <> path <> " (" <> format_file_error(cause) <> ")"
    CannotWriteFile(path, cause) ->
      "cannot write file: " <> path <> " (" <> format_file_error(cause) <> ")"
    ParseFailed(path, _cause) ->
      path <> ": failed to parse as Gleam source (glance.module error)"
    EmptyModulePath(path) ->
      path <> ": could not derive module segments (path produced empty list)"
    UnresolvedTypeModule(module_path, type_name) ->
      "type `"
      <> type_name
      <> "` from module `"
      <> module_path
      <> "` could not be resolved to a file path"
      <> "\n  ensure the module is in a path dep of the client package"
    TypeNotFound(module_path, type_name) ->
      "type `"
      <> type_name
      <> "` was not found in module `"
      <> module_path
      <> "`"
      <> "\n  the type may be private, or the module path may be incorrect"
    MissingSharedState(expected_path) ->
      "missing server/shared_state.gleam: expected at `"
      <> expected_path
      <> "`"
      <> "\n  create a module exporting the `SharedState` type"
    MissingAppError(expected_path) ->
      "missing server/app_error.gleam: expected at `"
      <> expected_path
      <> "`"
      <> "\n  create a module exporting the `AppError` type"
    MissingHandler(message_module, expected_path) ->
      "missing handler for message module `"
      <> message_module
      <> "`: expected at `"
      <> expected_path
      <> "`"
      <> "\n  create a handler module with a `update_from_client` function"
    NoMessageModules(shared_path) ->
      "no message modules found under `"
      <> shared_path
      <> "`"
      <> "\n  create a shared module exporting a `MsgFromClient` or `MsgFromServer` type"
  }
  io.println_error("error: " <> message)
}

fn format_file_error(err: simplifile.FileError) -> String {
  simplifile.describe_error(err)
}
