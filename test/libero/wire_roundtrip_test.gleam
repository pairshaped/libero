/// Exhaustive wire codec roundtrip tests (ETF).
///
/// Each test encodes a Gleam value, wraps it in a call envelope
/// {<<"shared/test">>, value}, decodes it back via wire.decode_call, and
/// asserts the original value survived. Since ETF preserves Erlang's
/// type structure, tuples roundtrip correctly (unlike JSON).
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/option.{None, Some}
import libero/wire

// ============================================================================
// Helpers
// ============================================================================

/// Encode a value, wrap it in a call envelope, decode it back.
/// The envelope is {<<"shared/test">>, value} - a 2-tuple where
/// the second element is the typed message value (not a list of args).
fn roundtrip(value: a) -> Dynamic {
  let envelope = ffi_encode(coerce(#("shared/test", coerce(value))))
  let assert Ok(#("shared/test", rebuilt)) = wire.decode_call(envelope)
  rebuilt
}

@external(erlang, "libero_ffi", "encode")
fn ffi_encode(value: Dynamic) -> BitArray

@external(erlang, "gleam_stdlib", "identity")
fn coerce(value: a) -> Dynamic

@external(erlang, "gleam_stdlib", "identity")
fn unsafe_coerce(value: Dynamic) -> a

// ============================================================================
// Primitive types
// ============================================================================

pub fn roundtrip_int_test() {
  let result: Int = unsafe_coerce(roundtrip(42))
  let assert 42 = result
}

pub fn roundtrip_negative_int_test() {
  let result: Int = unsafe_coerce(roundtrip(-7))
  let assert -7 = result
}

pub fn roundtrip_zero_test() {
  let result: Int = unsafe_coerce(roundtrip(0))
  let assert 0 = result
}

pub fn roundtrip_large_int_test() {
  let result: Int = unsafe_coerce(roundtrip(999_999_999))
  let assert 999_999_999 = result
}

pub fn roundtrip_float_test() {
  let result: Float = unsafe_coerce(roundtrip(3.14))
  let assert True = result >. 3.13 && result <. 3.15
}

pub fn roundtrip_negative_float_test() {
  let result: Float = unsafe_coerce(roundtrip(-2.5))
  let assert True = result <. -2.4 && result >. -2.6
}

pub fn roundtrip_string_test() {
  let result: String = unsafe_coerce(roundtrip("hello world"))
  let assert "hello world" = result
}

pub fn roundtrip_empty_string_test() {
  let result: String = unsafe_coerce(roundtrip(""))
  let assert "" = result
}

pub fn roundtrip_unicode_string_test() {
  let result: String = unsafe_coerce(roundtrip("Leve-tot 🎯"))
  let assert "Leve-tot 🎯" = result
}

pub fn roundtrip_bool_true_test() {
  let result: Bool = unsafe_coerce(roundtrip(True))
  let assert True = result
}

pub fn roundtrip_bool_false_test() {
  let result: Bool = unsafe_coerce(roundtrip(False))
  let assert False = result
}

pub fn roundtrip_nil_test() {
  let _result: Nil = unsafe_coerce(roundtrip(Nil))
}

// ============================================================================
// Option type
// ============================================================================

pub fn roundtrip_some_int_test() {
  let result: option.Option(Int) = unsafe_coerce(roundtrip(Some(42)))
  let assert Some(42) = result
}

pub fn roundtrip_some_string_test() {
  let result: option.Option(String) = unsafe_coerce(roundtrip(Some("hello")))
  let assert Some("hello") = result
}

pub fn roundtrip_none_test() {
  let result: option.Option(Int) = unsafe_coerce(roundtrip(None))
  let assert None = result
}

pub fn roundtrip_nested_some_test() {
  let result: option.Option(option.Option(Int)) =
    unsafe_coerce(roundtrip(Some(Some(99))))
  let assert Some(Some(99)) = result
}

pub fn roundtrip_nested_none_test() {
  let result: option.Option(option.Option(Int)) =
    unsafe_coerce(roundtrip(Some(None)))
  let assert Some(None) = result
}

// ============================================================================
// Result type
// ============================================================================

pub fn roundtrip_ok_test() {
  let result: Result(String, String) = unsafe_coerce(roundtrip(Ok("success")))
  let assert Ok("success") = result
}

pub fn roundtrip_error_test() {
  let result: Result(String, String) = unsafe_coerce(roundtrip(Error("fail")))
  let assert Error("fail") = result
}

pub fn roundtrip_ok_with_list_test() {
  let result: Result(List(Int), String) =
    unsafe_coerce(roundtrip(Ok([1, 2, 3])))
  let assert Ok([1, 2, 3]) = result
}

// ============================================================================
// List type
// ============================================================================

pub fn roundtrip_empty_list_test() {
  let result: List(Int) = unsafe_coerce(roundtrip([]))
  let assert [] = result
}

pub fn roundtrip_int_list_test() {
  let result: List(Int) = unsafe_coerce(roundtrip([1, 2, 3]))
  let assert [1, 2, 3] = result
}

pub fn roundtrip_string_list_test() {
  let result: List(String) = unsafe_coerce(roundtrip(["a", "b", "c"]))
  let assert ["a", "b", "c"] = result
}

pub fn roundtrip_nested_list_test() {
  let result: List(List(Int)) = unsafe_coerce(roundtrip([[1, 2], [3, 4]]))
  let assert [[1, 2], [3, 4]] = result
}

// ============================================================================
// Tuple type (ETF preserves tuples - no degradation to lists!)
// ============================================================================

pub fn roundtrip_2_tuple_test() {
  let result: #(String, Int) = unsafe_coerce(roundtrip(#("hello", 42)))
  let assert #("hello", 42) = result
}

pub fn roundtrip_3_tuple_test() {
  let result: #(Int, String, Bool) = unsafe_coerce(roundtrip(#(1, "two", True)))
  let assert #(1, "two", True) = result
}

// ============================================================================
// Dict type
// ============================================================================

pub fn roundtrip_empty_dict_test() {
  let result: dict.Dict(String, Int) = unsafe_coerce(roundtrip(dict.new()))
  let assert 0 = dict.size(result)
}

pub fn roundtrip_string_int_dict_test() {
  let input = dict.from_list([#("a", 1), #("b", 2)])
  let result: dict.Dict(String, Int) = unsafe_coerce(roundtrip(input))
  let assert Ok(1) = dict.get(result, "a")
  let assert Ok(2) = dict.get(result, "b")
  let assert 2 = dict.size(result)
}

pub fn roundtrip_dict_with_list_values_test() {
  let input =
    dict.from_list([
      #("colors", ["red", "blue"]),
      #("sizes", ["s", "m", "l"]),
    ])
  let result: dict.Dict(String, List(String)) = unsafe_coerce(roundtrip(input))
  let assert Ok(["red", "blue"]) = dict.get(result, "colors")
  let assert Ok(["s", "m", "l"]) = dict.get(result, "sizes")
}

pub fn roundtrip_dict_with_tuple_values_test() {
  // ETF preserves tuples, so unlike JSON this works correctly
  let input =
    dict.from_list([
      #("gender", [#("male", "Male"), #("female", "Female")]),
      #("size", [#("s", "Small"), #("m", "Medium")]),
    ])
  let result: dict.Dict(String, List(#(String, String))) =
    unsafe_coerce(roundtrip(input))
  let assert Ok([#("male", "Male"), #("female", "Female")]) =
    dict.get(result, "gender")
}

// ============================================================================
// Custom types (0-arity - bare atoms on BEAM)
// ============================================================================

pub fn roundtrip_none_is_distinct_from_nil_test() {
  let none_result: option.Option(Int) = unsafe_coerce(roundtrip(None))
  let assert None = none_result

  let _nil_result: Nil = unsafe_coerce(roundtrip(Nil))
}

// ============================================================================
// Custom types (N-arity - tuples on BEAM)
// ============================================================================

pub fn roundtrip_some_with_option_value_test() {
  let result: option.Option(String) = unsafe_coerce(roundtrip(Some("test")))
  let assert Some("test") = result
}

pub fn roundtrip_ok_with_complex_value_test() {
  // Ok wrapping a tuple - ETF preserves tuples!
  let result: Result(#(String, Int, Bool), Nil) =
    unsafe_coerce(roundtrip(Ok(#("a", 1, True))))
  let assert Ok(#("a", 1, True)) = result
}

// ============================================================================
// Compound/nested types (realistic shapes)
// ============================================================================

pub fn roundtrip_list_of_options_test() {
  let input = [Some(1), None, Some(3)]
  let result: List(option.Option(Int)) = unsafe_coerce(roundtrip(input))
  let assert [Some(1), None, Some(3)] = result
}

pub fn roundtrip_result_with_option_test() {
  let input: Result(option.Option(String), String) = Ok(Some("hello"))
  let result: Result(option.Option(String), String) =
    unsafe_coerce(roundtrip(input))
  let assert Ok(Some("hello")) = result
}

pub fn roundtrip_dict_with_option_values_test() {
  let input = dict.from_list([#("a", Some(1)), #("b", None)])
  let result: dict.Dict(String, option.Option(Int)) =
    unsafe_coerce(roundtrip(input))
  let assert Ok(Some(1)) = dict.get(result, "a")
  let assert Ok(None) = dict.get(result, "b")
}
