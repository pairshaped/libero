//// Direct tests for `walker.walk_shared_types`.
////
//// Existing coverage is incidental through wire_e2e and codegen integration
//// tests. These tests assert directly on the DiscoveredType output so a
//// regression in walker logic surfaces here, not three layers downstream.

import gleam/int
import gleam/list
import libero/walker.{type DiscoveredType}
import simplifile

const fixture_root = "build/.test_walker"

pub fn walks_mutually_recursive_types_test() {
  let dir = fixture_root <> "/mutual/shared/src/shared"
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(Nil) =
    simplifile.write(
      dir <> "/types.gleam",
      "pub type A {
  ANode(child: B)
  ALeaf
}

pub type B {
  BNode(child: A)
  BLeaf
}
",
    )

  let assert Ok(types) = walker.walk_shared_types(shared_src: dir)

  // Both types discovered exactly once each (no infinite loop on the cycle).
  let assert True = has_type(types, "A")
  let assert True = has_type(types, "B")
  let assert 1 = count_type(types, "A")
  let assert 1 = count_type(types, "B")

  let assert Ok(Nil) = simplifile.delete_all([fixture_root <> "/mutual"])
}

pub fn detects_float_field_indices_test() {
  let dir = fixture_root <> "/floats/shared/src/shared"
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(Nil) =
    simplifile.write(
      dir <> "/types.gleam",
      "pub type Mixed {
  Mixed(name: String, score: Float, count: Int, ratio: Float)
}
",
    )

  let assert Ok(types) = walker.walk_shared_types(shared_src: dir)

  let assert Ok(mixed) = find_type(types, "Mixed")
  let assert [variant] = mixed.variants
  // Float fields are at indices 1 (score) and 3 (ratio).
  let assert [1, 3] = list.sort(variant.float_field_indices, by: int.compare)

  let assert Ok(Nil) = simplifile.delete_all([fixture_root <> "/floats"])
}

pub fn returns_empty_for_directory_with_no_public_types_test() {
  let dir = fixture_root <> "/empty/shared/src/shared"
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(Nil) =
    simplifile.write(
      dir <> "/types.gleam",
      "// Only a private type - walker should not surface it.
type Hidden {
  Hidden(value: Int)
}
",
    )

  let assert Ok(types) = walker.walk_shared_types(shared_src: dir)
  let assert [] = types

  let assert Ok(Nil) = simplifile.delete_all([fixture_root <> "/empty"])
}

fn has_type(types: List(DiscoveredType), name: String) -> Bool {
  list.any(types, fn(t) { t.type_name == name })
}

fn count_type(types: List(DiscoveredType), name: String) -> Int {
  list.length(list.filter(types, fn(t) { t.type_name == name }))
}

fn find_type(
  types: List(DiscoveredType),
  name: String,
) -> Result(DiscoveredType, Nil) {
  list.find(types, fn(t) { t.type_name == name })
}
