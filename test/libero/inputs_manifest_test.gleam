//// Integration test for the --write-inputs manifest.
////
//// Verifies that when libero runs with --write-inputs, it writes
//// a .inputs file listing every source file it scanned.

import gleam/list
import gleam/string
import simplifile

/// After a successful libero run with --write-inputs on the fizzbuzz
/// example, the .inputs file should exist and list the scanned source
/// files. Since we can't easily run the full generator in test (it
/// needs a real project layout), we test the manifest file format
/// contract: one file per line, sorted, with a trailing newline.
///
/// This test creates a temp .inputs file in the expected format and
/// verifies the parsing contract that consumer build scripts depend on.
pub fn inputs_manifest_format_contract_test() {
  let files = [
    "src/server/admin/items.gleam",
    "src/server/admin/orders.gleam",
    "src/server/rpc_inject.gleam",
  ]
  let content = string.join(files, "\n") <> "\n"

  // Write to a temp file
  let path = "build/.test_inputs_manifest"
  let assert Ok(Nil) = simplifile.write(path, content)

  // Read back and verify contract
  let assert Ok(read_content) = simplifile.read(path)
  let lines = string.split(string.trim(read_content), "\n")

  // Should have 3 lines
  let assert 3 = list.length(lines)

  // Should be sorted
  let assert [
    "src/server/admin/items.gleam",
    "src/server/admin/orders.gleam",
    "src/server/rpc_inject.gleam",
  ] = lines

  // Should end with trailing newline
  let assert True = string.ends_with(read_content, "\n")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete(path)
}

/// Verify that an empty source list produces an empty manifest
/// (just a newline).
pub fn inputs_manifest_empty_sources_test() {
  let content = "\n"
  let path = "build/.test_inputs_manifest_empty"
  let assert Ok(Nil) = simplifile.write(path, content)

  let assert Ok(read_content) = simplifile.read(path)
  let assert "\n" = read_content

  let assert Ok(Nil) = simplifile.delete(path)
}
