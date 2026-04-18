import gleam/list
import gleam/string
import libero/codegen
import libero/scanner
import libero/walker

pub fn collision_produces_distinct_decoders_test() {
  let fixture = "fixtures/collision/shared/src/shared"
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: fixture)
  let assert Ok(types) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )

  // Both a.Status and b.Status must appear in the discovered graph.
  let names =
    list.map(types, fn(t) { t.module_path <> "." <> t.type_name })
  let assert True = list.contains(names, "shared/a.Status")
  let assert True = list.contains(names, "shared/b.Status")

  // The generated JS must contain a distinct function per type.
  let js = codegen.emit_typed_decoders(types)
  let assert True =
    string.contains(js, "export function decode_shared_a_status(term)")
  let assert True =
    string.contains(js, "export function decode_shared_b_status(term)")

  // And each decoder must construct instances from its own module:
  let assert True = string.contains(js, "new _m_shared_a.Paid()")
  let assert True = string.contains(js, "new _m_shared_b.Paid()")
}
