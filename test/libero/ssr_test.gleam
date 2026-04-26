import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/option.{None, Some}
import gleam/string
import libero/error.{PanicInfo}
import libero/ssr
import libero/wire
import lustre/element as lustre_element

@external(erlang, "gleam_stdlib", "identity")
fn coerce(value: a) -> Dynamic

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

pub fn call_with_expect_extracts_payload_test() {
  // Simulate a dispatch handler that returns Ok(payload)
  let handler = fn(_state: Nil, data: BitArray) {
    // Decode the call, ignore the module/msg, return a canned response
    let _ = data
    let response =
      wire.tag_response(request_id: 0, data: wire.encode(Ok("pong")))
    #(response, None, Nil)
  }
  let result =
    ssr.call(
      handle: handler,
      state: Nil,
      module: "test",
      msg: "ping",
      expect: fn(resp) { resp },
    )
  let assert Ok("pong") = result
}

pub fn call_expect_transforms_response_test() {
  let handler = fn(_state: Nil, data: BitArray) {
    let _ = data
    let response =
      wire.tag_response(request_id: 0, data: wire.encode(Ok("hello")))
    #(response, None, Nil)
  }
  let result =
    ssr.call(
      handle: handler,
      state: Nil,
      module: "test",
      msg: "ping",
      expect: fn(resp: String) { string.length(resp) },
    )
  let assert Ok(5) = result
}

pub fn call_returns_bad_response_on_error_response_test() {
  let handler = fn(_state: Nil, data: BitArray) {
    let _ = data
    let response =
      wire.tag_response(
        request_id: 0,
        data: wire.encode(Error("something went wrong")),
      )
    #(response, None, Nil)
  }
  let result: Result(String, ssr.SsrError) =
    ssr.call(
      handle: handler,
      state: Nil,
      module: "test",
      msg: "ping",
      expect: fn(resp) { resp },
    )
  let assert Error(ssr.BadResponse) = result
}

pub fn call_returns_bad_response_on_empty_bytes_test() {
  let handler = fn(_state: Nil, _data: BitArray) { #(<<>>, None, Nil) }
  let result: Result(String, ssr.SsrError) =
    ssr.call(
      handle: handler,
      state: Nil,
      module: "test",
      msg: "ping",
      expect: fn(resp) { resp },
    )
  let assert Error(ssr.BadResponse) = result
}

// --- ssr.document ---

pub fn document_contains_title_and_body_test() {
  let flags_value = "abc123"
  let html =
    ssr.document(
      title: "Test Page",
      body: "<p>Hello</p>",
      flags: flags_value,
      client_module: "/web/app.mjs",
    )
  let assert True = string.contains(html, "<title>Test Page</title>")
  let assert True = string.contains(html, "<p>Hello</p>")
  // flags are base64-encoded ETF, not the raw value
  let encoded_flags = ssr.encode_flags(flags_value)
  let assert True = string.contains(html, encoded_flags)
  let assert True = string.contains(html, "/web/app.mjs")
}

// --- decode_flags ---

pub fn decode_flags_roundtrip_test() {
  let value = "server flags"
  let encoded = ssr.encode_flags(value)
  let flags = coerce(encoded)
  let assert Ok(decoded) = ssr.decode_flags(flags)
  let assert True = decoded == value
}

pub fn decode_flags_bad_base64_returns_bad_flags_test() {
  let flags = coerce("not!valid!base64!!!")
  let assert Error(ssr.BadFlags) = ssr.decode_flags(flags)
}

pub fn decode_flags_corrupt_etf_returns_bad_flags_test() {
  // Valid base64 but not valid ETF
  let bad_base64 = bit_array.base64_encode(<<0, 1, 2, 3>>, True)
  let flags = coerce(bad_base64)
  let assert Error(ssr.BadFlags) = ssr.decode_flags(flags)
}

// --- ssr.call panic path ---

pub fn call_returns_dispatch_error_on_panic_test() {
  let handler = fn(_state: Nil, _data: BitArray) {
    let panic_info = PanicInfo(trace_id: "t1", fn_name: "test", reason: "boom")
    #(<<>>, Some(panic_info), Nil)
  }
  let result: Result(String, ssr.SsrError) =
    ssr.call(
      handle: handler,
      state: Nil,
      module: "test",
      msg: "ping",
      expect: fn(resp) { resp },
    )
  let assert Error(ssr.DispatchError) = result
}

// --- ssr.boot_script ---

pub fn boot_script_embeds_encoded_flags_test() {
  let flags = "hello world"
  let encoded = ssr.encode_flags(flags)
  let el = ssr.boot_script(client_module: "/web/app.mjs", flags:)
  let html_str = lustre_element.to_string(el)
  let assert True = string.contains(html_str, encoded)
}

pub fn boot_script_includes_client_module_test() {
  let el = ssr.boot_script(client_module: "/web/app.mjs", flags: 0)
  let html_str = lustre_element.to_string(el)
  let assert True = string.contains(html_str, "/web/app.mjs")
  let assert True = string.contains(html_str, "main()")
}

pub fn boot_script_sets_window_flags_global_test() {
  let el = ssr.boot_script(client_module: "/x.mjs", flags: 1)
  let html_str = lustre_element.to_string(el)
  let assert True = string.contains(html_str, "window.__LIBERO_FLAGS__")
}

pub fn boot_script_module_script_is_module_type_test() {
  let el = ssr.boot_script(client_module: "/x.mjs", flags: 1)
  let html_str = lustre_element.to_string(el)
  // The import script must be type="module" or the import statement is invalid.
  let assert True = string.contains(html_str, "type=\"module\"")
}

// --- escape_html XSS ---

pub fn document_escapes_xss_in_title_test() {
  let xss_title = "<script>alert(\"xss\")</script>"
  let html =
    ssr.document(
      title: xss_title,
      body: "",
      flags: Nil,
      client_module: "/app.mjs",
    )
  // The raw script tag must NOT appear in the output
  let assert False = string.contains(html, "<script>alert(")
  // The escaped version should appear instead
  let assert True =
    string.contains(html, "&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;")
}
