import gleam/bit_array
import gleam/option.{None}
import gleam/string
import libero/ssr
import libero/wire

// --- encode_flags / decode_flags roundtrip ---

pub fn encode_decode_flags_roundtrip_test() {
  let value = "hello from the server"
  let encoded = ssr.encode_flags(value)
  // Should be a non-empty base64 string
  let assert True = string.length(encoded) > 0
  // Roundtrip through encode -> base64 -> decode
  let assert Ok(etf) = bit_array.base64_decode(encoded)
  let decoded: String = wire.decode(etf)
  let assert True = decoded == value
}

pub fn encode_flags_produces_valid_base64_test() {
  let encoded = ssr.encode_flags(42)
  // Should only contain valid base64 characters
  let assert Ok(_) = bit_array.base64_decode(encoded)
}

// --- ssr.call ---

pub fn call_returns_decoded_payload_test() {
  // Simulate a dispatch handler that returns Ok(payload)
  let handler = fn(_state: Nil, data: BitArray) {
    // Decode the call, ignore the module/msg, return a canned response
    let _ = data
    let response = wire.tag_response(wire.encode(Ok("pong")))
    #(response, None, Nil)
  }
  let result =
    ssr.call(
      handle: handler,
      state: Nil,
      module: "test",
      msg: "ping",
    )
  let assert Ok("pong") = result
}

pub fn call_returns_dispatch_error_on_error_response_test() {
  let handler = fn(_state: Nil, data: BitArray) {
    let _ = data
    let response = wire.tag_response(wire.encode(Error("something went wrong")))
    #(response, None, Nil)
  }
  let result: Result(String, ssr.SsrError) =
    ssr.call(
      handle: handler,
      state: Nil,
      module: "test",
      msg: "ping",
    )
  let assert Error(ssr.DispatchError) = result
}

pub fn call_returns_bad_response_on_empty_bytes_test() {
  let handler = fn(_state: Nil, _data: BitArray) {
    #(<<>>, None, Nil)
  }
  let result: Result(String, ssr.SsrError) =
    ssr.call(
      handle: handler,
      state: Nil,
      module: "test",
      msg: "ping",
    )
  let assert Error(ssr.BadResponse) = result
}

// --- ssr.document ---

pub fn document_contains_title_and_body_test() {
  let html =
    ssr.document(
      title: "Test Page",
      body: "<p>Hello</p>",
      flags: "abc123",
      client_module: "/web/app.mjs",
    )
  let assert True = string.contains(html, "<title>Test Page</title>")
  let assert True = string.contains(html, "<p>Hello</p>")
  let assert True = string.contains(html, "abc123")
  let assert True = string.contains(html, "/web/app.mjs")
}
