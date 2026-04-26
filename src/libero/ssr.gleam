//// Helpers for server-side rendering with Libero.
////
//// Server-side: call a dispatch handler directly, encode flags for
//// the HTML document, and render the full page shell.
////
//// Client-side: read and decode flags embedded by the server.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{type Option}
import gleam/result
import gleam/uri.{type Uri, Uri}
import libero/error.{type PanicInfo}
import libero/wire
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import mist.{type ResponseData}

pub type SsrError {
  BadResponse
  DispatchError
  BadFlags
}

/// Call a dispatch handler directly on the server, returning a
/// decoded payload. Encodes the call envelope, invokes the handler,
/// strips the wire framing, and passes the response through the
/// `expect` function to extract the desired value.
///
/// The response is the handler's return type (e.g. `Result(Int, Nil)`).
///
/// ```gleam
/// ssr.call(
///   handle: dispatch.handle,
///   handler_ctx:,
///   module: "rpc",
///   msg: GetCounter,
///   expect: fn(resp) {
///     let assert Ok(n) = resp
///     n
///   },
/// )
/// // Returns Result(Int, SsrError)
/// ```
pub fn call(
  handle handle: fn(state, BitArray) -> #(BitArray, Option(PanicInfo), state),
  handler_ctx handler_ctx: state,
  module module: String,
  msg msg: msg,
  expect expect: fn(response) -> payload,
) -> Result(payload, SsrError) {
  let data = wire.encode_call(module:, request_id: 0, msg:)
  let #(response_bytes, maybe_panic, _new_handler_ctx) =
    handle(handler_ctx, data)
  case maybe_panic {
    option.Some(_) -> Error(DispatchError)
    option.None ->
      case response_bytes {
        <<_tag, _request_id:32, etf:bytes>> -> {
          // dispatch encodes Ok(handler_return_value) or Error(RpcError).
          // wire.decode_safe returns a Result instead of panicking.
          let decoded: Result(Result(response, _), _) = wire.decode_safe(etf)
          case decoded {
            Ok(Ok(response)) -> Ok(expect(response))
            Ok(Error(_)) | Error(_) -> Error(BadResponse)
          }
        }
        _ -> Error(BadResponse)
      }
  }
}

/// Encode a value as a base64 ETF string, ready to embed in HTML
/// as client flags.
pub fn encode_flags(data: a) -> String {
  data
  |> wire.encode
  |> bit_array.base64_encode(True)
}

/// Decode flags from a Dynamic value (base64 ETF string).
/// Use this in a Lustre init function to decode server-embedded flags.
pub fn decode_flags(flags: Dynamic) -> Result(a, SsrError) {
  case decode.run(flags, decode.string) {
    Error(_) -> Error(BadFlags)
    Ok(encoded) ->
      bit_array.base64_decode(encoded)
      |> result.replace_error(BadFlags)
      |> result.try(fn(bytes) {
        wire.decode_safe(bytes)
        |> result.replace_error(BadFlags)
      })
  }
}

/// Render a fragment of two `<script>` elements that boot the client app:
/// one assigns the base64-encoded ETF flags to `window.__LIBERO_FLAGS__`,
/// the other imports `client_module` as an ES module and calls `main()`.
///
/// Drop this in your document tree (typically at the end of `<body>`)
/// when building a server-rendered page.
///
/// ```gleam
/// html.body([], [
///   html.div([attribute.id("app")], [views.view(model)]),
///   ssr.boot_script(client_module: "/web/app.mjs", flags: model),
/// ])
/// ```
///
/// `client_module` is a JS import path controlled by the developer, not user
/// input — it is concatenated into the generated `<script type="module">`
/// without escaping. If you derive this value from external input, you must
/// validate it yourself.
pub fn boot_script(
  client_module client_module: String,
  flags flags: a,
) -> Element(msg) {
  let encoded = encode_flags(flags)
  // encoded is base64 (alphabet [A-Za-z0-9+/=]) — safe inside a JS string literal.
  element.fragment([
    html.script([], "window.__LIBERO_FLAGS__ = \"" <> encoded <> "\";"),
    html.script(
      [attribute.type_("module")],
      "import { main } from \"" <> client_module <> "\";\nmain();",
    ),
  ])
}

/// Render a server-side page for an HTTP request.
///
/// Pipeline: `parse(uri)` -> `load(req, route, handler_ctx)` -> `render(route, model)` ->
/// HTML response.
///
/// - Non-GET requests get a `405 Method Not Allowed`.
/// - `parse` returning `Error(Nil)` gets a bare `404 Not Found`. Custom 404
///   pages: handle the catch-all in your mist router and only call
///   `handle_request` for paths you recognize.
/// - `load` returning `Error(response)` returns that exact response: the
///   loader owns auth redirects, soft 404s with custom bodies, etc.
/// - `load` returning `Ok(model)` renders the document tree from `render`
///   into a `200 OK` HTML response.
///
/// ```gleam
/// ssr.handle_request(
///   req:,
///   parse: views.parse_route,
///   load: load_page,
///   render: render_page,
///   handler_ctx:,
/// )
/// ```
pub fn handle_request(
  req req: Request(body),
  parse parse: fn(Uri) -> Result(route, Nil),
  load load: fn(Request(body), route, state) ->
    Result(model, Response(ResponseData)),
  render render: fn(route, model) -> Element(msg),
  handler_ctx handler_ctx: state,
) -> Response(ResponseData) {
  case req.method {
    http.Get -> {
      let uri = request_to_uri(req)
      case parse(uri) {
        Error(Nil) -> empty_response(404)
        Ok(route) ->
          case load(req, route, handler_ctx) {
            Error(response) -> response
            Ok(model) -> render_response(render(route, model))
          }
      }
    }
    _ -> empty_response(405)
  }
}

fn request_to_uri(req: Request(body)) -> Uri {
  Uri(
    scheme: option.None,
    userinfo: option.None,
    host: option.None,
    port: option.None,
    path: req.path,
    query: req.query,
    fragment: option.None,
  )
}

fn render_response(el: Element(msg)) -> Response(ResponseData) {
  let html_str = element.to_document_string(el)
  response.new(200)
  |> response.set_header("content-type", "text/html")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(html_str)))
}

fn empty_response(status: Int) -> Response(ResponseData) {
  response.new(status)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}
