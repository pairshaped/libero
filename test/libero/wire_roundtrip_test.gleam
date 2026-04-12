/// Exhaustive wire codec roundtrip tests.
///
/// Each test encodes a Gleam value via wire.encode (server-side encoder),
/// verifies the JSON shape, then decodes it back via wire.decode_call's
/// rebuild function (server-side decoder that mirrors the client-side
/// rpc_ffi.mjs rebuild). This exercises the full Gleam→JSON→Gleam path
/// for every type that can cross the wire.
///
/// The client-side (JS) encoder and decoder are symmetric by design — if
/// the server-side roundtrip works, the JS side should too (modulo JS
/// runtime quirks, which are tested separately in the fizzbuzz example).
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/io
import gleam/option.{None, Some}
import gleam/string
import libero/wire

// ============================================================================
// Helpers
// ============================================================================

/// Encode a value with the server encoder, then wrap it as an RPC call
/// arg and decode it back via decode_call's rebuild. Returns the rebuilt
/// Dynamic value for assertion.
fn roundtrip(value: a) -> Dynamic {
  // Encode the value
  let encoded = wire.encode(value)
  // Wrap it as a fake RPC call with one arg
  let call_json = "{\"fn\":\"test\",\"args\":[" <> encoded <> "]}"
  let assert Ok(#("test", [rebuilt])) = wire.decode_call(call_json)
  rebuilt
}

/// Unsafe coerce for test assertions — we know the type because we
/// just encoded it.
@external(erlang, "gleam_stdlib", "identity")
fn coerce(value: Dynamic) -> a

// ============================================================================
// Primitive types
// ============================================================================

pub fn roundtrip_int_test() {
  let result: Int = coerce(roundtrip(42))
  let assert 42 = result
  io.println("roundtrip Int: OK")
}

pub fn roundtrip_negative_int_test() {
  let result: Int = coerce(roundtrip(-7))
  let assert -7 = result
  io.println("roundtrip negative Int: OK")
}

pub fn roundtrip_zero_test() {
  let result: Int = coerce(roundtrip(0))
  let assert 0 = result
  io.println("roundtrip zero: OK")
}

pub fn roundtrip_float_test() {
  let result: Float = coerce(roundtrip(3.14))
  let assert True = result >. 3.13 && result <. 3.15
  io.println("roundtrip Float: OK")
}

pub fn roundtrip_string_test() {
  let result: String = coerce(roundtrip("hello world"))
  let assert "hello world" = result
  io.println("roundtrip String: OK")
}

pub fn roundtrip_empty_string_test() {
  let result: String = coerce(roundtrip(""))
  let assert "" = result
  io.println("roundtrip empty String: OK")
}

pub fn roundtrip_unicode_string_test() {
  let result: String = coerce(roundtrip("Lève-tôt 🎯"))
  let assert "Lève-tôt 🎯" = result
  io.println("roundtrip unicode String: OK")
}

pub fn roundtrip_bool_true_test() {
  let result: Bool = coerce(roundtrip(True))
  let assert True = result
  io.println("roundtrip Bool True: OK")
}

pub fn roundtrip_bool_false_test() {
  let result: Bool = coerce(roundtrip(False))
  let assert False = result
  io.println("roundtrip Bool False: OK")
}

pub fn roundtrip_nil_test() {
  let result: Nil = coerce(roundtrip(Nil))
  let assert Nil = result
  io.println("roundtrip Nil: OK")
}

// ============================================================================
// Option type
// ============================================================================

pub fn roundtrip_some_int_test() {
  let result: option.Option(Int) = coerce(roundtrip(Some(42)))
  let assert Some(42) = result
  io.println("roundtrip Some(Int): OK")
}

pub fn roundtrip_some_string_test() {
  let result: option.Option(String) = coerce(roundtrip(Some("hello")))
  let assert Some("hello") = result
  io.println("roundtrip Some(String): OK")
}

pub fn roundtrip_none_test() {
  let result: option.Option(Int) = coerce(roundtrip(None))
  let assert None = result
  io.println("roundtrip None: OK")
}

pub fn roundtrip_nested_some_test() {
  let result: option.Option(option.Option(Int)) =
    coerce(roundtrip(Some(Some(99))))
  let assert Some(Some(99)) = result
  io.println("roundtrip Some(Some(Int)): OK")
}

pub fn roundtrip_nested_none_test() {
  let result: option.Option(option.Option(Int)) =
    coerce(roundtrip(Some(None)))
  let assert Some(None) = result
  io.println("roundtrip Some(None): OK")
}

// ============================================================================
// Result type
// ============================================================================

pub fn roundtrip_ok_test() {
  let result: Result(String, String) = coerce(roundtrip(Ok("success")))
  let assert Ok("success") = result
  io.println("roundtrip Ok: OK")
}

pub fn roundtrip_error_test() {
  let result: Result(String, String) = coerce(roundtrip(Error("fail")))
  let assert Error("fail") = result
  io.println("roundtrip Error: OK")
}

// ============================================================================
// List type
// ============================================================================

pub fn roundtrip_empty_list_test() {
  let result: List(Int) = coerce(roundtrip([]))
  let assert [] = result
  io.println("roundtrip empty List: OK")
}

pub fn roundtrip_int_list_test() {
  let result: List(Int) = coerce(roundtrip([1, 2, 3]))
  let assert [1, 2, 3] = result
  io.println("roundtrip List(Int): OK")
}

pub fn roundtrip_string_list_test() {
  let result: List(String) = coerce(roundtrip(["a", "b", "c"]))
  let assert ["a", "b", "c"] = result
  io.println("roundtrip List(String): OK")
}

pub fn roundtrip_nested_list_test() {
  let result: List(List(Int)) = coerce(roundtrip([[1, 2], [3, 4]]))
  let assert [[1, 2], [3, 4]] = result
  io.println("roundtrip nested List: OK")
}

// ============================================================================
// Tuple type
// ============================================================================

// KNOWN LIMITATION: plain tuples (no atom tag in position 0) encode
// as JSON arrays and decode back as Gleam lists, not tuples. This is
// because JSON has no tuple type — both `[1, "a"]` (Gleam tuple) and
// `[1, "a"]` (Gleam list) produce the same JSON shape. Custom types
// are NOT affected because they have an atom tag that distinguishes
// them. For now, if a consumer needs tuples to roundtrip, they should
// wrap them in a custom type.

pub fn roundtrip_2_tuple_decodes_as_list_test() {
  // Tuples decode as lists — known limitation
  let result: List(Dynamic) = coerce(roundtrip(#("hello", 42)))
  let assert [_a, _b] = result
  io.println("roundtrip 2-tuple → list (known limitation): OK")
}

pub fn roundtrip_3_tuple_decodes_as_list_test() {
  let result: List(Dynamic) = coerce(roundtrip(#(1, "two", True)))
  let assert [_a, _b, _c] = result
  io.println("roundtrip 3-tuple → list (known limitation): OK")
}

// ============================================================================
// Dict type
// ============================================================================

pub fn roundtrip_empty_dict_test() {
  let result: dict.Dict(String, Int) = coerce(roundtrip(dict.new()))
  let assert 0 = dict.size(result)
  io.println("roundtrip empty Dict: OK")
}

pub fn roundtrip_string_int_dict_test() {
  let input = dict.from_list([#("a", 1), #("b", 2)])
  let result: dict.Dict(String, Int) = coerce(roundtrip(input))
  let assert Ok(1) = dict.get(result, "a")
  let assert Ok(2) = dict.get(result, "b")
  let assert 2 = dict.size(result)
  io.println("roundtrip Dict(String, Int): OK")
}

pub fn roundtrip_dict_with_list_values_test() {
  let input =
    dict.from_list([
      #("colors", ["red", "blue"]),
      #("sizes", ["s", "m", "l"]),
    ])
  let result: dict.Dict(String, List(String)) = coerce(roundtrip(input))
  let assert Ok(["red", "blue"]) = dict.get(result, "colors")
  let assert Ok(["s", "m", "l"]) = dict.get(result, "sizes")
  io.println("roundtrip Dict with List values: OK")
}

pub fn roundtrip_dict_with_tuple_list_values_test() {
  // Matches AdminData.question_options shape: Dict(String, List(#(String, String)))
  // Note: inner tuples decode as lists due to the tuple/list limitation
  let input =
    dict.from_list([
      #("gender", [#("male", "Male"), #("female", "Female")]),
      #("size", [#("s", "Small"), #("m", "Medium")]),
    ])
  let result: dict.Dict(String, List(List(String))) =
    coerce(roundtrip(input))
  let assert Ok([["male", "Male"], ["female", "Female"]]) =
    dict.get(result, "gender")
  io.println("roundtrip Dict with tuple-list values (tuples → lists): OK")
}

// ============================================================================
// Custom types (0-arity — bare atoms on BEAM)
// ============================================================================

// We can't test app-specific custom types (DiscountNotFound, Male, etc.)
// directly in libero's test suite because those types aren't defined here.
// But we CAN test the framework types that libero itself defines, plus
// Option.None which is a 0-arity constructor.

pub fn roundtrip_none_is_bare_atom_test() {
  // None encodes as {"@":"none","v":[]} (tagged 0-arity constructor),
  // NOT as null. Nil encodes as null. They are different atoms on BEAM.
  let encoded = wire.encode(None)
  let assert True = string.contains(encoded, "\"@\":\"none\"")
  let result: option.Option(Int) = coerce(roundtrip(None))
  let assert None = result
  io.println("roundtrip None as bare atom: OK")
}

// ============================================================================
// Custom types (N-arity — tuples on BEAM)
// ============================================================================

pub fn roundtrip_some_with_option_value_test() {
  // Some is a 1-arity custom type: tuple {some, Value}
  let result: option.Option(String) = coerce(roundtrip(Some("test")))
  let assert Some("test") = result
  io.println("roundtrip Some (1-arity custom type): OK")
}

pub fn roundtrip_ok_with_complex_value_test() {
  // Ok wrapping a tuple — inner tuple decodes as list (known limitation)
  let result: Result(List(Dynamic), Nil) =
    coerce(roundtrip(Ok(#("a", 1, True))))
  let assert Ok([_a, _b, _c]) = result
  io.println("roundtrip Ok(tuple) → Ok(list): OK")
}

// ============================================================================
// Compound/nested types (realistic shapes)
// ============================================================================

pub fn roundtrip_list_of_options_test() {
  let input = [Some(1), None, Some(3)]
  let result: List(option.Option(Int)) = coerce(roundtrip(input))
  let assert [Some(1), None, Some(3)] = result
  io.println("roundtrip List(Option(Int)): OK")
}

pub fn roundtrip_result_with_option_test() {
  let input: Result(option.Option(String), String) = Ok(Some("hello"))
  let result: Result(option.Option(String), String) = coerce(roundtrip(input))
  let assert Ok(Some("hello")) = result
  io.println("roundtrip Result(Option(String), String): OK")
}

pub fn roundtrip_dict_with_option_values_test() {
  let input = dict.from_list([#("a", Some(1)), #("b", None)])
  let result: dict.Dict(String, option.Option(Int)) =
    coerce(roundtrip(input))
  let assert Ok(Some(1)) = dict.get(result, "a")
  let assert Ok(None) = dict.get(result, "b")
  io.println("roundtrip Dict with Option values: OK")
}

// ============================================================================
// Wire format shape verification (not just roundtrip — check the JSON)
// ============================================================================

pub fn encode_none_is_tagged_test() {
  // None is a 0-arity constructor — encoded as tagged, not null.
  // Nil (the unit type) encodes as null. They are distinct.
  let encoded = wire.encode(None)
  let assert True = string.contains(encoded, "\"@\":\"none\"")
  io.println("encode None → tagged (not null): OK")
}

pub fn encode_some_is_tagged_test() {
  let encoded = wire.encode(Some(42))
  let assert True = string.contains(encoded, "\"@\":\"some\"")
  let assert True = string.contains(encoded, "42")
  io.println("encode Some → tagged: OK")
}

pub fn encode_dict_is_tagged_test() {
  let encoded = wire.encode(dict.from_list([#("k", "v")]))
  let assert True = string.contains(encoded, "\"@\":\"dict\"")
  io.println("encode Dict → tagged dict: OK")
}

pub fn encode_empty_list_is_array_test() {
  let encoded = wire.encode([])
  let assert "[]" = encoded
  io.println("encode [] → []: OK")
}

pub fn encode_list_is_array_test() {
  let encoded = wire.encode([1, 2, 3])
  let assert "[1,2,3]" = encoded
  io.println("encode [1,2,3] → [1,2,3]: OK")
}

pub fn encode_true_is_true_test() {
  let assert "true" = wire.encode(True)
  io.println("encode True → true: OK")
}

pub fn encode_false_is_false_test() {
  let assert "false" = wire.encode(False)
  io.println("encode False → false: OK")
}

pub fn encode_nil_is_null_test() {
  let assert "null" = wire.encode(Nil)
  io.println("encode Nil → null: OK")
}

// ============================================================================
// decode_call specific tests (verifying arg rebuild in isolation)
// ============================================================================

pub fn decode_empty_args_test() {
  let assert Ok(#("fn", [])) =
    wire.decode_call("{\"fn\":\"fn\",\"args\":[]}")
  io.println("decode_call empty args: OK")
}

pub fn decode_primitive_args_test() {
  let assert Ok(#("fn", [_a, _b, _c])) =
    wire.decode_call("{\"fn\":\"fn\",\"args\":[42,\"hello\",true]}")
  io.println("decode_call primitive args: OK")
}

pub fn decode_tagged_arg_test() {
  let json =
    "{\"fn\":\"fn\",\"args\":[{\"@\":\"some\",\"v\":[99]}]}"
  let assert Ok(#("fn", [arg])) = wire.decode_call(json)
  let result: option.Option(Int) = coerce(arg)
  let assert Some(99) = result
  io.println("decode_call tagged arg → Some(99): OK")
}

pub fn decode_none_arg_test() {
  let json =
    "{\"fn\":\"fn\",\"args\":[{\"@\":\"none\",\"v\":[]}]}"
  let assert Ok(#("fn", [arg])) = wire.decode_call(json)
  let result: option.Option(Int) = coerce(arg)
  let assert None = result
  io.println("decode_call tagged None arg: OK")
}

pub fn decode_null_arg_test() {
  let json = "{\"fn\":\"fn\",\"args\":[null]}"
  let assert Ok(#("fn", [arg])) = wire.decode_call(json)
  let result: Nil = coerce(arg)
  let assert Nil = result
  io.println("decode_call null arg → Nil: OK")
}

pub fn decode_dict_arg_test() {
  let json =
    "{\"fn\":\"fn\",\"args\":[{\"@\":\"dict\",\"v\":[[\"a\",1],[\"b\",2]]}]}"
  let assert Ok(#("fn", [arg])) = wire.decode_call(json)
  let result: dict.Dict(String, Int) = coerce(arg)
  let assert Ok(1) = dict.get(result, "a")
  let assert Ok(2) = dict.get(result, "b")
  io.println("decode_call dict arg: OK")
}

pub fn decode_nested_custom_type_arg_test() {
  // Some(Some(42)) — nested N-arity constructors
  let json =
    "{\"fn\":\"fn\",\"args\":[{\"@\":\"some\",\"v\":[{\"@\":\"some\",\"v\":[42]}]}]}"
  let assert Ok(#("fn", [arg])) = wire.decode_call(json)
  let result: option.Option(option.Option(Int)) = coerce(arg)
  let assert Some(Some(42)) = result
  io.println("decode_call nested custom type: OK")
}

pub fn decode_list_of_tagged_args_test() {
  let json =
    "{\"fn\":\"fn\",\"args\":[[{\"@\":\"some\",\"v\":[1]},{\"@\":\"none\",\"v\":[]},{\"@\":\"some\",\"v\":[3]}]]}"
  let assert Ok(#("fn", [arg])) = wire.decode_call(json)
  let result: List(option.Option(Int)) = coerce(arg)
  let assert [Some(1), None, Some(3)] = result
  io.println("decode_call list of tagged values: OK")
}
