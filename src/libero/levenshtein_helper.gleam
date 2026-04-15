//// Thin public wrapper around the generator's levenshtein function,
//// exposed only so tests can exercise it directly. Not part of
//// libero's public API.

import gleam/list
import gleam/string

/// Levenshtein distance between two strings.
pub fn distance(from a: String, to b: String) -> Int {
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
    // Unreachable: final_row always has at least one element (init_row
    // starts with [0] for empty strings).
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
