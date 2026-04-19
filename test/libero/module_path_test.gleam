import libero/codegen
import libero/scanner

// -- derive_module_path tests --

pub fn derive_module_path_standard_test() {
  let assert "core/messages" =
    scanner.derive_module_path(
      file_path: "examples/todos/src/core/messages.gleam",
    )
}

pub fn derive_module_path_nested_test() {
  let assert "shared/admin/items" =
    scanner.derive_module_path(
      file_path: "/some/project/shared/src/shared/admin/items.gleam",
    )
}

pub fn derive_module_path_root_module_test() {
  let assert "shared" =
    scanner.derive_module_path(file_path: "project/src/shared.gleam")
}

pub fn derive_module_path_no_src_segment_test() {
  let assert "some/path/module" =
    scanner.derive_module_path(file_path: "some/path/module.gleam")
}

// -- module_to_mjs_path tests --

pub fn module_to_mjs_multi_segment_test() {
  let assert "core/core/messages.mjs" =
    codegen.module_to_mjs_path("core/messages")
}

pub fn module_to_mjs_single_segment_test() {
  let assert "shared/shared.mjs" = codegen.module_to_mjs_path("shared")
}

pub fn module_to_mjs_deep_path_test() {
  let assert "shared/shared/admin/items.mjs" =
    codegen.module_to_mjs_path("shared/admin/items")
}

// -- extract_dir tests --

pub fn extract_dir_nested_test() {
  let assert "src/server/generated/libero" =
    codegen.extract_dir("src/server/generated/libero/dispatch.gleam")
}

pub fn extract_dir_single_file_test() {
  let assert "." = codegen.extract_dir("file.gleam")
}

pub fn extract_dir_one_level_test() {
  let assert "src" = codegen.extract_dir("src/file.gleam")
}
