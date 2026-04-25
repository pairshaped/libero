//// Tests for type alias walk-through in the type graph walker.
////
//// Type aliases should be transparent: the walker should resolve them
//// to their underlying type and continue walking transitively.

import gleam/list
import libero/field_type
import libero/scanner
import libero/walker

const fixture = "fixtures/type_alias/shared/src/shared"

/// A type alias to a primitive (Score = Int) should not produce an error.
/// The walker should succeed and the message variant using it should be present.
pub fn alias_to_primitive_walks_successfully_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: fixture)
  let assert Ok(types) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let variants = list.flat_map(types, fn(t) { t.variants })
  let names = list.map(variants, fn(v) { v.variant_name })
  let assert True = list.contains(names, "GotScore")
}

/// A type alias to a custom type (UserPriority = Priority) should cause
/// the walker to discover the underlying custom type transitively.
pub fn alias_to_custom_type_discovers_underlying_type_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: fixture)
  let assert Ok(types) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let type_names = list.map(types, fn(t) { t.type_name })
  // Priority (the real custom type) should be discovered
  let assert True = list.contains(type_names, "Priority")
  // Its variants should all be present
  let variants = list.flat_map(types, fn(t) { t.variants })
  let variant_names = list.map(variants, fn(v) { v.variant_name })
  let assert True = list.contains(variant_names, "High")
  let assert True = list.contains(variant_names, "Medium")
  let assert True = list.contains(variant_names, "Low")
}

/// A type alias wrapping a container (ItemList = List(Item)) should cause
/// the walker to discover the custom type inside the container.
pub fn alias_to_container_discovers_inner_type_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: fixture)
  let assert Ok(types) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let type_names = list.map(types, fn(t) { t.type_name })
  // Item (the custom type inside List(Item)) should be discovered
  let assert True = list.contains(type_names, "Item")
  // Its variant should be present
  let variants = list.flat_map(types, fn(t) { t.variants })
  let variant_names = list.map(variants, fn(v) { v.variant_name })
  let assert True = list.contains(variant_names, "Item")
}

/// The GotPriority variant should have a UserType field pointing to Priority,
/// not an error or missing field.
pub fn alias_field_resolves_to_correct_field_type_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: fixture)
  let assert Ok(types) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let variants = list.flat_map(types, fn(t) { t.variants })
  let assert Ok(got_priority) =
    list.find(variants, fn(v) { v.variant_name == "GotPriority" })
  // The field should be a UserType pointing to shared/item.Priority
  let assert [
    field_type.UserType(
      module_path: "shared/item",
      type_name: "Priority",
      args: [],
    ),
  ] = got_priority.fields
}

/// The GotItems variant should have a ListOf(UserType) field.
pub fn alias_container_field_resolves_correctly_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: fixture)
  let assert Ok(types) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let variants = list.flat_map(types, fn(t) { t.variants })
  let assert Ok(got_items) =
    list.find(variants, fn(v) { v.variant_name == "GotItems" })
  // The field should be ListOf(UserType(shared/item, Item))
  let assert [
    field_type.ListOf(field_type.UserType(
      module_path: "shared/item",
      type_name: "Item",
      args: [],
    )),
  ] = got_items.fields
}
