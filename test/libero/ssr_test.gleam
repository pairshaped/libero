import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic.{type Dynamic}
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import gleam/uri as gleam_uri
import libero/error.{PanicInfo}
import libero/ssr
import libero/wire
import lustre/element as lustre_element
import lustre/element/html as html_el
import mist

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
      handler_ctx: Nil,
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
      handler_ctx: Nil,
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
      handler_ctx: Nil,
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
      handler_ctx: Nil,
      module: "test",
      msg: "ping",
      expect: fn(resp) { resp },
    )
  let assert Error(ssr.BadResponse) = result
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
      handler_ctx: Nil,
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

// --- ssr.handle_request ---

type FakeRoute {
  HomeRoute
  PostRoute(id: Int)
}

type FakeModel {
  FakeModel(route: FakeRoute, value: Int)
}

type FakeState {
  FakeState(default: Int)
}

fn fake_parse(uri: gleam_uri.Uri) -> Result(FakeRoute, Nil) {
  case gleam_uri.path_segments(uri.path) {
    [] | ["home"] -> Ok(HomeRoute)
    ["posts", id_str] ->
      case int.parse(id_str) {
        Ok(id) -> Ok(PostRoute(id))
        Error(Nil) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn fake_render(
  _route: FakeRoute,
  model: FakeModel,
) -> lustre_element.Element(Nil) {
  html_el.html([], [
    html_el.body([], [
      html_el.p([], [html_el.text("value=" <> int.to_string(model.value))]),
    ]),
  ])
}

fn fake_load_ok(
  _req: request.Request(String),
  route: FakeRoute,
  handler_ctx: FakeState,
) -> Result(FakeModel, response.Response(mist.ResponseData)) {
  Ok(FakeModel(route:, value: handler_ctx.default))
}

fn fake_load_err(
  _req: request.Request(String),
  _route: FakeRoute,
  _state: FakeState,
) -> Result(FakeModel, response.Response(mist.ResponseData)) {
  Error(
    response.new(302)
    |> response.set_header("location", "/login")
    |> response.set_body(mist.Bytes(bytes_tree.new())),
  )
}

fn get_request(path: String) -> request.Request(String) {
  request.new()
  |> request.set_method(http.Get)
  |> request.set_path(path)
}

fn extract_body_string(resp: response.Response(mist.ResponseData)) -> String {
  case resp.body {
    mist.Bytes(tree) -> {
      let bits = bytes_tree.to_bit_array(tree)
      case bit_array.to_string(bits) {
        Ok(s) -> s
        Error(_) -> ""
      }
    }
    _ -> ""
  }
}

pub fn handle_request_returns_405_on_post_test() {
  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/home")
  let resp =
    ssr.handle_request(
      req:,
      parse: fake_parse,
      load: fake_load_ok,
      render: fake_render,
      handler_ctx: FakeState(default: 0),
    )
  let assert 405 = resp.status
}

pub fn handle_request_returns_404_when_parse_fails_test() {
  let req = get_request("/no-such-route")
  let resp =
    ssr.handle_request(
      req:,
      parse: fake_parse,
      load: fake_load_ok,
      render: fake_render,
      handler_ctx: FakeState(default: 0),
    )
  let assert 404 = resp.status
}

pub fn handle_request_returns_loader_error_response_test() {
  let req = get_request("/home")
  let resp =
    ssr.handle_request(
      req:,
      parse: fake_parse,
      load: fake_load_err,
      render: fake_render,
      handler_ctx: FakeState(default: 0),
    )
  let assert 302 = resp.status
  let assert Ok("/login") = response.get_header(resp, "location")
}

pub fn handle_request_renders_200_on_success_test() {
  let req = get_request("/home")
  let resp =
    ssr.handle_request(
      req:,
      parse: fake_parse,
      load: fake_load_ok,
      render: fake_render,
      handler_ctx: FakeState(default: 7),
    )
  let assert 200 = resp.status
  let assert Ok("text/html") = response.get_header(resp, "content-type")
  let body = extract_body_string(resp)
  let assert True = string.contains(body, "<!doctype html>")
  let assert True = string.contains(body, "value=7")
}

pub fn handle_request_passes_route_with_params_to_loader_test() {
  let req = get_request("/posts/42")
  let captured =
    ssr.handle_request(
      req:,
      parse: fake_parse,
      load: fn(_req, route, _state) {
        case route {
          PostRoute(id) -> Ok(FakeModel(route:, value: id))
          _ -> Ok(FakeModel(route:, value: -1))
        }
      },
      render: fake_render,
      handler_ctx: FakeState(default: 0),
    )
  let body = extract_body_string(captured)
  let assert True = string.contains(body, "value=42")
}
