//// Tests for libero/trace - the panic-catching + trace_id primitives.
////
//// These are the building blocks behind the generated dispatch's
//// panic handling: every /// @rpc call runs inside try_call, and a
//// panic surfaces to the consumer as an InternalError envelope
//// tagged with a fresh trace_id.

import gleam/string
import libero/trace

// ---------- try_call ----------

pub fn try_call_success_returns_ok_test() {
  let assert Ok(42) = trace.try_call(fn() { 42 })
}

pub fn try_call_returns_value_verbatim_test() {
  let assert Ok("hello") = trace.try_call(fn() { "hello" })
}

pub fn try_call_catches_explicit_panic_test() {
  let result = trace.try_call(fn() { panic as "you asked for it" })
  let assert Error(reason) = result
  // The stringified Erlang exception mentions the panic message
  // somewhere in its body; we assert containment rather than
  // equality because the exact format includes file/line metadata
  // that changes across Gleam versions.
  let assert True = string.contains(reason, "you asked for it")
}

pub fn try_call_catches_division_by_zero_test() {
  // Gleam's / operator on integers is defined to return 0 on
  // division by zero (deliberately total), so this tests that
  // SUCCESSFUL integer division through a function body still
  // comes back as Ok - it should not be mistaken for a panic.
  let assert Ok(0) = trace.try_call(fn() { 10 / 0 })
}

// ---------- new_trace_id ----------

pub fn new_trace_id_is_12_chars_test() {
  let id = trace.new_trace_id()
  let assert 12 = string.length(id)
}

pub fn new_trace_id_is_hex_test() {
  // 6 bytes of entropy as base16 uses only 0-9 and A-F.
  let id = trace.new_trace_id()
  let assert True = is_base16(id)
}

pub fn new_trace_id_is_unique_test() {
  // Two consecutive calls should virtually never collide. If they
  // do, crypto.strong_random_bytes is broken.
  let id1 = trace.new_trace_id()
  let id2 = trace.new_trace_id()
  let assert False = id1 == id2
}

// ---------- helpers ----------

fn is_base16(value: String) -> Bool {
  value
  |> string.to_graphemes
  |> do_all_base16
}

fn do_all_base16(chars: List(String)) -> Bool {
  case chars {
    [] -> True
    [c, ..rest] ->
      case is_hex_char(c) {
        True -> do_all_base16(rest)
        False -> False
      }
  }
}

fn is_hex_char(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    "A" | "B" | "C" | "D" | "E" | "F" -> True
    _ -> False
  }
}
