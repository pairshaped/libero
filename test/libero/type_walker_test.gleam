//// Integration tests for the type graph walker.
////
//// Tests `walk_message_registry_types` using the real todos example,
//// which indirectly exercises `build_type_resolver` and `collect_type_refs`.

import gleam/dict
import gleam/list
import gleam/set
import libero/scanner
import libero/walker

pub fn walk_discovers_toserver_variants_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(
      shared_src: "examples/todos/shared/src/shared",
    )
  let assert Ok(discovered) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let names = list.map(discovered, fn(v) { v.variant_name })
  let assert True = list.contains(names, "Create")
  let assert True = list.contains(names, "Toggle")
  let assert True = list.contains(names, "Delete")
  let assert True = list.contains(names, "LoadAll")
}

pub fn walk_discovers_toclient_variants_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(
      shared_src: "examples/todos/shared/src/shared",
    )
  let assert Ok(discovered) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let names = list.map(discovered, fn(v) { v.variant_name })
  let assert True = list.contains(names, "Created")
  let assert True = list.contains(names, "Toggled")
  let assert True = list.contains(names, "Deleted")
  let assert True = list.contains(names, "AllLoaded")
  let assert True = list.contains(names, "TodoFailed")
}

pub fn walk_discovers_transitive_types_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(
      shared_src: "examples/todos/shared/src/shared",
    )
  let assert Ok(discovered) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let names = list.map(discovered, fn(v) { v.variant_name })
  let assert True = list.contains(names, "Todo")
  let assert True = list.contains(names, "TodoParams")
  let assert True = list.contains(names, "NotFound")
  let assert True = list.contains(names, "TitleRequired")
}

pub fn walk_atom_names_are_snake_case_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(
      shared_src: "examples/todos/shared/src/shared",
    )
  let assert Ok(discovered) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let assert True =
    list.all(discovered, fn(v) {
      v.atom_name == walker.to_snake_case(v.variant_name)
    })
}

pub fn walk_no_duplicates_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(
      shared_src: "examples/todos/shared/src/shared",
    )
  let assert Ok(discovered) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let names = list.map(discovered, fn(v) { v.variant_name })
  let unique = set.from_list(names) |> set.to_list
  let assert True = list.length(names) == list.length(unique)
}

pub fn walk_empty_module_files_returns_error_test() {
  let modules = [
    scanner.MessageModule(
      module_path: "nonexistent/module",
      file_path: "/tmp/nonexistent.gleam",
      has_msg_from_client: True,
      has_msg_from_server: False,
      handler_modules: [],
    ),
  ]
  let assert Error(_errors) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: dict.new(),
    )
}
