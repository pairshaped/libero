//// Tests for the full pipeline - walk the type graph on the todos
//// example and verify the discovered variants include all expected
//// constructors (MsgFromClient, MsgFromServer, and transitive types).

import gleam/list
import gleam/string
import libero/codegen
import libero/scanner
import libero/walker
import simplifile

pub fn walk_and_write_dispatch_atoms_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: "examples/todos/shared/src/shared")

  let assert Ok(discovered) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )

  // Write dispatch to verify it works end-to-end
  let output_dir = "build/.test_codegen_atoms"
  let assert Ok(Nil) =
    codegen.write_dispatch(
      message_modules: modules,
      server_generated: output_dir,
      atoms_module: "test@rpc_atoms",
    )
  let assert Ok(dispatch) = simplifile.read(output_dir <> "/dispatch.gleam")

  // Dispatch must reference the atoms module
  let assert True = string.contains(dispatch, "test@rpc_atoms")

  // Verify discovered variants include MsgFromClient and MsgFromServer constructors
  let variant_names = list.map(discovered, fn(v) { v.variant_name })

  // MsgFromClient variants
  let assert True = list.contains(variant_names, "Create")
  let assert True = list.contains(variant_names, "Toggle")
  let assert True = list.contains(variant_names, "Delete")
  let assert True = list.contains(variant_names, "LoadAll")

  // MsgFromServer variants
  let assert True = list.contains(variant_names, "TodoCreated")
  let assert True = list.contains(variant_names, "TodoToggled")
  let assert True = list.contains(variant_names, "TodoDeleted")
  let assert True = list.contains(variant_names, "TodosLoaded")

  // Transitive types
  let assert True = list.contains(variant_names, "Todo")
  let assert True = list.contains(variant_names, "TodoParams")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}
