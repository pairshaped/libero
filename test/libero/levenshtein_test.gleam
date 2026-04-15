//// Tests for the Levenshtein distance function.
//// The implementation lives here (test-only) since it is not used
//// by any library code. If a typo-detection feature is added to
//// the generator in the future, move the function into src/.

import gleam/list
import gleam/string

pub fn identical_strings_test() {
  let assert 0 = distance(from: "tz_db", to: "tz_db")
}

pub fn single_insertion_test() {
  // tzdb -> tz_db (insert underscore)
  let assert 1 = distance(from: "tzdb", to: "tz_db")
}

pub fn single_deletion_test() {
  let assert 1 = distance(from: "tz_db", to: "tzdb")
}

pub fn single_substitution_test() {
  let assert 1 = distance(from: "conn", to: "cont")
}

pub fn two_edits_test() {
  // connn -> conn (delete) then conn -> cont (substitute) = 2
  let assert 2 = distance(from: "connn", to: "cont")
}

pub fn completely_different_test() {
  // key vs lang = 4 edits (all different chars, different length)
  let assert True = distance(from: "key", to: "lang") > 2
}

pub fn empty_vs_nonempty_test() {
  let assert 5 = distance(from: "", to: "hello")
}

pub fn both_empty_test() {
  let assert 0 = distance(from: "", to: "")
}

pub fn real_world_inject_typo_test() {
  // The original issue: tzdb vs tz_db should be caught (distance 1)
  let assert True = distance(from: "tzdb", to: "tz_db") <= 2
}

pub fn real_world_false_positive_test() {
  // key vs lang should NOT be caught (distance > 2)
  let assert True = distance(from: "key", to: "lang") > 2
}

pub fn real_world_false_positive_slug_test() {
  // slug vs lang should NOT be caught
  let assert True = distance(from: "slug", to: "lang") > 2
}

pub fn real_world_false_positive_name_test() {
  // name vs conn should NOT be caught
  let assert True = distance(from: "name", to: "conn") > 2
}

// ---------- Levenshtein implementation (test-only) ----------

fn distance(from a: String, to b: String) -> Int {
  let a_chars = string.to_graphemes(a)
  let b_chars = string.to_graphemes(b)
  let b_len = list.length(b_chars)

  let init_row = build_range(from: 0, to: b_len)

  let #(final_row, _) =
    list.fold(a_chars, #(init_row, 1), fn(state, a_char) {
      let #(prev_row, i) = state
      let #(new_row_rev, _) =
        list.fold(b_chars, #([i], 1), fn(inner, b_char) {
          let row_so_far = inner.0
          let col = inner.1
          let above = head_or_zero(row_so_far)
          let diag = at(items: prev_row, index: col - 1)
          let left = above
          let up = at(items: prev_row, index: col)
          let cost = case a_char == b_char {
            True -> 0
            False -> 1
          }
          let val = min3(a: diag + cost, b: left + 1, c: up + 1)
          #([val, ..row_so_far], col + 1)
        })
      #(list.reverse(new_row_rev), i + 1)
    })

  case list.last(final_row) {
    Ok(d) -> d
    Error(Nil) -> 0
  }
}

fn build_range(from from: Int, to to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..build_range(from: from + 1, to: to)]
  }
}

fn head_or_zero(items: List(Int)) -> Int {
  case items {
    [x, ..] -> x
    [] -> 0
  }
}

fn at(items items: List(Int), index index: Int) -> Int {
  case items, index {
    [x, ..], 0 -> x
    [_, ..rest], n -> at(items: rest, index: n - 1)
    [], _ -> 0
  }
}

fn min3(a a: Int, b b: Int, c c: Int) -> Int {
  let ab = case a < b {
    True -> a
    False -> b
  }
  case ab < c {
    True -> ab
    False -> c
  }
}
