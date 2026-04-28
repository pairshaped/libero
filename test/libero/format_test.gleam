import birdie
import libero/format

pub fn format_returns_normalised_when_input_parses_test() {
  let input = "pub fn   add(a: Int,b:Int)->Int{a+b}\n"
  let output = format.format_gleam(input)
  birdie.snap(output, title: "format gleam normalised output")
}

pub fn format_falls_back_to_input_when_unparseable_test() {
  // Garbage that gleam format cannot parse. The function must still
  // return a String and never panic; callers depend on this so that
  // codegen produces some output even when the formatter is unhappy.
  let garbled = "this is not valid gleam ;;;{{{}}}"
  let output = format.format_gleam(garbled)
  let assert True = output == garbled
}
