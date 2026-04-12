import gleam/dict
import gleam/io
import gleam/string
import libero/wire

// ---------- decode_call tests (server-side arg parsing) ----------

pub fn decode_call_empty_args_test() {
  let text = "{\"fn\":\"admin.discounts.load_admin_data\",\"args\":[]}"
  let assert Ok(#(name, args)) = wire.decode_call(text)
  let assert "admin.discounts.load_admin_data" = name
  let assert [] = args
  io.println("decode empty args: OK")
}

pub fn decode_call_primitive_args_test() {
  let text = "{\"fn\":\"admin.discounts.delete\",\"args\":[42]}"
  let assert Ok(#(name, args)) = wire.decode_call(text)
  let assert "admin.discounts.delete" = name
  let assert [_id] = args
  io.println("decode primitive args: OK")
}

pub fn decode_call_tagged_custom_type_arg_test() {
  // Simulate a DiscountParams-like tagged object arriving from the client
  let text =
    "{\"fn\":\"admin.discounts.create\",\"args\":[{\"@\":\"discount_params\",\"v\":[\"Test Discount\",null,10.0,0,true,false,false,false,[],null,null,null,null,null,false,null,null,null]}]}"
  let assert Ok(#(name, [_params])) = wire.decode_call(text)
  let assert "admin.discounts.create" = name
  io.println("decode tagged custom type arg: OK")
}

pub fn decode_call_nested_tagged_arg_test() {
  // Option(Gender) — Some(Male) encoded as {"@":"some","v":[{"@":"male","v":[]}]}
  let text =
    "{\"fn\":\"test\",\"args\":[{\"@\":\"some\",\"v\":[{\"@\":\"male\",\"v\":[]}]}]}"
  let assert Ok(#("test", [_value])) = wire.decode_call(text)
  io.println("decode nested tagged arg: OK")
}

// ---------- encode tests (server-side response encoding) ----------

pub fn encode_primitive_ok_test() {
  let result = wire.encode(Ok("hello"))
  let assert True = string.contains(result, "\"@\":\"ok\"")
  let assert True = string.contains(result, "hello")
  io.println("encode primitive Ok: OK")
}

pub fn encode_result_with_dict_test() {
  // Simulate AdminData with a Dict field
  let data =
    dict.from_list([#("key1", "value1"), #("key2", "value2")])
  let result = wire.encode(Ok(data))
  let assert True = string.contains(result, "\"@\":\"dict\"")
  let assert True = string.contains(result, "key1")
  io.println("encode Result with Dict: OK")
}

pub fn encode_list_of_tuples_test() {
  let data = [#("a", "b"), #("c", "d")]
  let result = wire.encode(data)
  let assert True = string.contains(result, "[")
  io.println("encode list of tuples: OK")
}

// ---------- roundtrip tests (encode → decode symmetry) ----------

pub fn roundtrip_tagged_type_test() {
  // Encode a custom type, then verify decode_call can parse args
  // containing the same shape
  let encoded = wire.encode(Ok("test_value"))
  let call_json =
    "{\"fn\":\"test\",\"args\":["
    <> encoded
    <> "]}"
  let assert Ok(#("test", [_rebuilt])) = wire.decode_call(call_json)
  io.println("roundtrip tagged type: OK")
}
