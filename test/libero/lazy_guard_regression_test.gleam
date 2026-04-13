//// Regression test for issue #9: bool.guard vs bool.lazy_guard.
////
//// The walker hung because bool.guard(when:, return: recursive_call())
//// eagerly evaluates the return expression regardless of the condition.
//// This test verifies that bool.lazy_guard correctly skips evaluation
//// when the condition matches, which is the property the fix depends on.

import gleam/bool

/// When the guard condition is true, lazy_guard should return the
/// thunk's value WITHOUT evaluating the continuation.
pub fn lazy_guard_skips_continuation_when_true_test() {
  let result = {
    use <- bool.lazy_guard(when: True, return: fn() { "skipped" })
    panic as "continuation was evaluated when it should have been skipped"
  }
  let assert "skipped" = result
}

/// When the guard condition is false, lazy_guard should NOT call
/// the thunk and should continue to the next expression.
pub fn lazy_guard_continues_when_false_test() {
  let result = {
    use <- bool.lazy_guard(when: False, return: fn() {
      panic as "thunk was evaluated when it should have been skipped"
    })
    "continued"
  }
  let assert "continued" = result
}

/// Verify that lazy_guard with a recursive-looking pattern terminates.
/// This mirrors the walker's structure: skip when visited, recurse when not.
/// Under bool.guard this would stack overflow; under lazy_guard it terminates.
pub fn lazy_guard_recursive_pattern_terminates_test() {
  let result = count_down(from: 100, visited: [])
  let assert 100 = result
}

fn count_down(from n: Int, visited visited: List(Int)) -> Int {
  use <- bool.lazy_guard(when: n <= 0, return: fn() { 0 })
  // Simulate the visited-set check that caused the original hang
  let already_visited = list_contains(visited, n)
  use <- bool.lazy_guard(when: already_visited, return: fn() {
    count_down(from: n - 1, visited: visited)
  })
  1 + count_down(from: n - 1, visited: [n, ..visited])
}

fn list_contains(items: List(Int), target: Int) -> Bool {
  case items {
    [] -> False
    [x, ..rest] ->
      case x == target {
        True -> True
        False -> list_contains(rest, target)
      }
  }
}
