//// Tests for libero/gen_error - error formatting and box drawing.

import glance
import gleam/option.{None, Some}
import gleam/string
import libero/gen_error.{
  CannotCreateDir, CannotReadDir, CannotReadFile, CannotWriteFile,
  DuplicateEndpoint, NoEndpointsFound, ParseFailed, TypeNotFound,
  UnresolvedTypeModule,
}
import simplifile

// -- error_box --

pub fn error_box_with_hint_test() {
  let result =
    gen_error.error_box(
      title: "Something broke",
      path: "src/handler.gleam",
      body_lines: ["The file could not be processed", "Check the syntax"],
      hint: Some("Run `gleam check` to see details"),
    )
  let assert True = string.contains(result, "error: Something broke")
  let assert True = string.contains(result, "src/handler.gleam")
  let assert True = string.contains(result, "The file could not be processed")
  let assert True = string.contains(result, "Check the syntax")
  let assert True = string.contains(result, "hint:")
  let assert True = string.contains(result, "Run `gleam check` to see details")
}

pub fn error_box_without_hint_test() {
  let result =
    gen_error.error_box(
      title: "Simple error",
      path: "gleam.toml",
      body_lines: ["One line of detail"],
      hint: None,
    )
  let assert True = string.contains(result, "error: Simple error")
  let assert True = string.contains(result, "gleam.toml")
  let assert True = string.contains(result, "One line of detail")
  let assert False = string.contains(result, "hint:")
}

pub fn error_box_with_multiline_body_test() {
  let result =
    gen_error.error_box(
      title: "Multi-line error",
      path: "src/app.gleam",
      body_lines: ["First issue", "Second issue", "Third issue"],
      hint: None,
    )
  let assert True = string.contains(result, "First issue")
  let assert True = string.contains(result, "Second issue")
  let assert True = string.contains(result, "Third issue")
}

// -- print_error covers every GenError variant (smoke: doesn't panic) --

pub fn print_error_cannot_read_dir_test() {
  let err = CannotReadDir(path: "src", cause: simplifile.Eacces)
  gen_error.print_error(err)
}

pub fn print_error_cannot_read_file_test() {
  let err = CannotReadFile(path: "src/handler.gleam", cause: simplifile.Eacces)
  gen_error.print_error(err)
}

pub fn print_error_cannot_write_file_test() {
  let err = CannotWriteFile(path: "src/out.gleam", cause: simplifile.Eacces)
  gen_error.print_error(err)
}

pub fn print_error_cannot_create_dir_test() {
  let err = CannotCreateDir(path: "src/gen", cause: simplifile.Eacces)
  gen_error.print_error(err)
}

pub fn print_error_parse_failed_test() {
  let err =
    ParseFailed(path: "src/broken.gleam", cause: glance.UnexpectedEndOfInput)
  gen_error.print_error(err)
}

pub fn print_error_unresolved_type_module_test() {
  let err =
    UnresolvedTypeModule(module_path: "shared/missing", type_name: "Foo")
  gen_error.print_error(err)
}

pub fn print_error_type_not_found_test() {
  let err = TypeNotFound(module_path: "shared/types", type_name: "Bar")
  gen_error.print_error(err)
}

pub fn print_error_no_endpoints_found_test() {
  let err = NoEndpointsFound(server_src: "src/server")
  gen_error.print_error(err)
}

pub fn print_error_duplicate_endpoint_test() {
  let err =
    DuplicateEndpoint(fn_name: "get_items", modules: ["server/a", "server/b"])
  gen_error.print_error(err)
}

// -- error_box covers DuplicateEndpoint multi-module list --

pub fn error_box_duplicate_endpoint_shows_modules_test() {
  let result =
    gen_error.error_box(
      title: "Duplicate handler endpoint",
      path: "get_items",
      body_lines: [
        "The same function name is exported from multiple handler",
        "modules:",
        "  server/handler_a",
        "  server/handler_b",
      ],
      hint: Some(
        "Handler function names must be unique across the server source\n        tree, since each one becomes a ClientMsg variant.",
      ),
    )
  let assert True = string.contains(result, "server/handler_a")
  let assert True = string.contains(result, "server/handler_b")
}

// -- error_box with empty body --

pub fn error_box_with_empty_body_test() {
  let result =
    gen_error.error_box(
      title: "No details",
      path: ".",
      body_lines: [],
      hint: None,
    )
  let assert True = string.contains(result, "error: No details")
}

// -- print_error with NoEndpointsFound and a long path --

pub fn print_error_no_endpoints_long_path_test() {
  let err = NoEndpointsFound(server_src: "some/deeply/nested/server/src")
  gen_error.print_error(err)
}
