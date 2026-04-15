import libero

// -- derive_module_path tests --

pub fn derive_module_path_standard_test() {
  let assert "shared/todos" =
    libero.derive_module_path(
      file_path: "examples/todos/shared/src/shared/todos.gleam",
    )
}

pub fn derive_module_path_nested_test() {
  let assert "shared/admin/items" =
    libero.derive_module_path(
      file_path: "/some/project/shared/src/shared/admin/items.gleam",
    )
}

pub fn derive_module_path_root_module_test() {
  let assert "shared" =
    libero.derive_module_path(file_path: "project/src/shared.gleam")
}

pub fn derive_module_path_no_src_segment_test() {
  let assert "some/path/module" =
    libero.derive_module_path(file_path: "some/path/module.gleam")
}

// -- module_to_mjs_path tests --

pub fn module_to_mjs_multi_segment_test() {
  let assert "shared/shared/todos.mjs" =
    libero.module_to_mjs_path("shared/todos")
}

pub fn module_to_mjs_single_segment_test() {
  let assert "shared/shared.mjs" = libero.module_to_mjs_path("shared")
}

pub fn module_to_mjs_deep_path_test() {
  let assert "shared/shared/admin/items.mjs" =
    libero.module_to_mjs_path("shared/admin/items")
}

// -- extract_dir tests --

pub fn extract_dir_nested_test() {
  let assert "src/server/generated/libero" =
    libero.extract_dir("src/server/generated/libero/dispatch.gleam")
}

pub fn extract_dir_single_file_test() {
  let assert "." = libero.extract_dir("file.gleam")
}

pub fn extract_dir_one_level_test() {
  let assert "src" = libero.extract_dir("src/file.gleam")
}
