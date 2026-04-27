import gleam/string
import libero/format

/// `format_gleam` shells out to `gleam format`. When the input parses,
/// the formatter normalizes whitespace; when it doesn't, the original
/// string is returned unchanged. Both paths must leave program semantics
/// alone — codegen would otherwise produce broken modules.
pub fn format_returns_normalised_when_input_parses_test() {
  let input = "pub fn   add(a: Int,b:Int)->Int{a+b}\n"
  let output = format.format_gleam(input)
  let assert True = string.contains(output, "pub fn add")
  let assert True = string.contains(output, "Int, b: Int")
}

pub fn format_falls_back_to_input_when_unparseable_test() {
  // Garbage that gleam format cannot parse. The function must still
  // return a String and never panic; callers depend on this so that
  // codegen produces some output even when the formatter is unhappy.
  let garbled = "this is not valid gleam ;;;{{{}}}"
  let output = format.format_gleam(garbled)
  let assert True = output == garbled
}
