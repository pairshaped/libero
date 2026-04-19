//// Tests for source scanning edge cases - symlink skipping,
//// generated/ directory exclusion, and module_files dict population.

import gleam/dict
import gleam/list
import libero/scanner
import simplifile

/// scan_message_modules should skip a "generated" subdirectory.
pub fn scan_skips_generated_directory_test() {
  let base = "build/.test_scanner_generated"
  let shared_src = base <> "/src/shared"

  // Create a message module and a generated/ subdirectory with a decoy
  let assert Ok(Nil) =
    simplifile.create_directory_all(shared_src <> "/generated")
  let assert Ok(Nil) =
    simplifile.write(
      shared_src <> "/msgs.gleam",
      "pub type MsgFromClient { Ping }",
    )
  let assert Ok(Nil) =
    simplifile.write(
      shared_src <> "/generated/decoy.gleam",
      "pub type MsgFromClient { Decoy }",
    )

  let assert Ok(#(modules, _files)) = scanner.scan_message_modules(shared_src:)
  // Should only find msgs, not decoy
  let assert 1 = list.length(modules)
  let assert [m] = modules
  let assert True = m.has_msg_from_client

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([base])
}

/// scan_message_modules should skip symlinks.
pub fn scan_skips_symlinks_test() {
  let base = "build/.test_scanner_symlinks"
  let shared_src = base <> "/src/shared"

  let assert Ok(Nil) = simplifile.create_directory_all(shared_src)
  let assert Ok(Nil) =
    simplifile.write(
      shared_src <> "/msgs.gleam",
      "pub type MsgFromClient { Ping }",
    )

  // Create a symlink pointing back to parent (potential cycle)
  let assert Ok(Nil) = simplifile.create_symlink("../..", shared_src <> "/loop")

  let assert Ok(#(modules, _files)) = scanner.scan_message_modules(shared_src:)
  let assert 1 = list.length(modules)

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([base])
}

/// module_files dict should contain all .gleam files, not just message modules.
pub fn scan_populates_module_files_for_all_gleam_files_test() {
  let base = "build/.test_scanner_module_files"
  let shared_src = base <> "/src/shared"

  let assert Ok(Nil) = simplifile.create_directory_all(shared_src)
  let assert Ok(Nil) =
    simplifile.write(
      shared_src <> "/msgs.gleam",
      "pub type MsgFromClient { Ping }",
    )
  let assert Ok(Nil) =
    simplifile.write(
      shared_src <> "/helper.gleam",
      "pub type Payload { Data(Int) }",
    )

  let assert Ok(#(_modules, files)) = scanner.scan_message_modules(shared_src:)
  // module_files should contain both files
  let assert 2 = dict.size(files)

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([base])
}

/// derive_module_path should handle core/ prefix correctly.
pub fn derive_module_path_core_test() {
  let assert "core/todos" =
    scanner.derive_module_path(file_path: "myapp/src/core/todos.gleam")
  let assert "core/messages/admin" =
    scanner.derive_module_path(file_path: "myapp/src/core/messages/admin.gleam")
}

/// derive_module_path should handle core/ with handler suffix.
pub fn derive_module_path_handler_test() {
  let assert "core/todos_handler" =
    scanner.derive_module_path(file_path: "myapp/src/core/todos_handler.gleam")
}
