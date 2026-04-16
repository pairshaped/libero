import glance
import gleam/int
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
  MissingHandler(message_module: String, expected: String)
  MsgFromServerFieldCount(
    module_path: String,
    variant_name: String,
    field_count: Int,
  )
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
    MsgFromServerFieldCount(module_path, variant_name, field_count) ->
      "MsgFromServer variant `"
      <> variant_name
      <> "` in `"
      <> module_path
      <> "` has "
      <> int.to_string(field_count)
      <> " field(s), expected exactly 1"
      <> "\n  each MsgFromServer variant must wrap a single value so dispatch can unwrap the envelope"
    MissingHandler(message_module, expected) ->
      "missing handler for message module `"
      <> message_module
      <> "`: expected "
      <> expected
      <> "\n  create a server module exporting `pub fn update_from_client` with the correct type annotation"
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
