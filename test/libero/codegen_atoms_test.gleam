//// Tests for the full v3 pipeline - walk the type graph on the todos
//// example and verify the discovered variants include all expected
//// constructors (ToServer, ToClient, and transitive types).

import gleam/list
import gleam/string
import libero
import simplifile

pub fn walk_and_write_dispatch_atoms_test() {
  let assert Ok(#(modules, module_files)) =
    libero.scan_message_modules(
      shared_src: "examples/todos/shared/src/shared",
    )

  let assert Ok(discovered) =
    libero.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )

  // Write dispatch to verify it works end-to-end
  let output_dir = "build/.test_codegen_atoms"
  let assert Ok(Nil) =
    libero.write_v3_dispatch(
      message_modules: modules,
      server_generated: output_dir,
      atoms_module: "test@rpc_atoms",
    )
  let assert Ok(dispatch) = simplifile.read(output_dir <> "/dispatch.gleam")

  // Dispatch must reference the atoms module
  let assert True = string.contains(dispatch, "test@rpc_atoms")

  // Verify discovered variants include ToServer and ToClient constructors
  let variant_names = list.map(discovered, fn(v) { v.variant_name })

  // ToServer variants
  let assert True = list.contains(variant_names, "Create")
  let assert True = list.contains(variant_names, "Toggle")
  let assert True = list.contains(variant_names, "Delete")
  let assert True = list.contains(variant_names, "LoadAll")

  // ToClient variants
  let assert True = list.contains(variant_names, "Created")
  let assert True = list.contains(variant_names, "Toggled")
  let assert True = list.contains(variant_names, "Deleted")
  let assert True = list.contains(variant_names, "AllLoaded")
  let assert True = list.contains(variant_names, "TodoFailed")

  // Transitive types
  let assert True = list.contains(variant_names, "Todo")
  let assert True = list.contains(variant_names, "TodoParams")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}
