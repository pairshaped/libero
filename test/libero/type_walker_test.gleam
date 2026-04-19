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
    scanner.scan_message_modules(shared_src: "examples/todos/shared/src/shared")
  let assert Ok(types) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let variants = list.flat_map(types, fn(t) { t.variants })
  let names = list.map(variants, fn(v) { v.variant_name })
  let assert True = list.contains(names, "Create")
  let assert True = list.contains(names, "Toggle")
  let assert True = list.contains(names, "Delete")
  let assert True = list.contains(names, "LoadAll")
}

pub fn walk_discovers_toclient_variants_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: "examples/todos/shared/src/shared")
  let assert Ok(types) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let variants = list.flat_map(types, fn(t) { t.variants })
  let names = list.map(variants, fn(v) { v.variant_name })
  let assert True = list.contains(names, "TodoCreated")
  let assert True = list.contains(names, "TodoToggled")
  let assert True = list.contains(names, "TodoDeleted")
  let assert True = list.contains(names, "TodosLoaded")
}

pub fn walk_discovers_transitive_types_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: "examples/todos/shared/src/shared")
  let assert Ok(types) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let variants = list.flat_map(types, fn(t) { t.variants })
  let names = list.map(variants, fn(v) { v.variant_name })
  let assert True = list.contains(names, "Todo")
  let assert True = list.contains(names, "TodoParams")
  let assert True = list.contains(names, "NotFound")
  let assert True = list.contains(names, "TitleRequired")
}

pub fn walk_atom_names_are_snake_case_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: "examples/todos/shared/src/shared")
  let assert Ok(types) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let variants = list.flat_map(types, fn(t) { t.variants })
  let assert True =
    list.all(variants, fn(v) {
      v.atom_name == walker.to_snake_case(v.variant_name)
    })
}

pub fn walk_no_duplicates_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: "examples/todos/shared/src/shared")
  let assert Ok(types) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let variants = list.flat_map(types, fn(t) { t.variants })
  let names = list.map(variants, fn(v) { v.variant_name })
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

pub fn walk_populates_primitive_field_types_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: "examples/todos/shared/src/shared")
  let assert Ok(types) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let variants = list.flat_map(types, fn(t) { t.variants })

  // TodoParams(title: String) carries a single String field.
  let assert Ok(todo_params) =
    list.find(variants, fn(v) { v.variant_name == "TodoParams" })
  let assert [walker.StringField] = todo_params.fields
}

pub fn walk_resolves_user_type_in_field_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: "examples/todos/shared/src/shared")
  let assert Ok(types) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let variants = list.flat_map(types, fn(t) { t.variants })

  // TodosLoaded(Result(List(Todo), TodoError)) - exercises Result, List, and UserType.
  let assert Ok(loaded) =
    list.find(variants, fn(v) { v.variant_name == "TodosLoaded" })
  let assert [
    walker.ResultOf(
      ok: walker.ListOf(walker.UserType(
        module_path: "shared/messages",
        type_name: "Todo",
        args: [],
      )),
      err: walker.UserType(
        module_path: "shared/messages",
        type_name: "TodoError",
        args: [],
      ),
    ),
  ] = loaded.fields
}

pub fn walk_groups_variants_under_type_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: "examples/todos/shared/src/shared")
  let assert Ok(types) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let assert Ok(msg_from_client) =
    list.find(types, fn(t) { t.type_name == "MsgFromClient" })
  let variant_count = list.length(msg_from_client.variants)
  let assert True = variant_count > 1
}
