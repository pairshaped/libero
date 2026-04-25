//// Helpers for server-side rendering with Libero.
////
//// Server-side: call a dispatch handler directly, encode flags for
//// the HTML document, and render the full page shell.
////
//// Client-side: read and decode flags embedded by the server.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/option.{type Option}
import gleam/result
import gleam/string
import libero/error.{type PanicInfo}
import libero/wire

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
/// With handler-as-contract, the response is the handler's return
/// type (e.g. `Result(Int, Nil)`), not a wrapped MsgFromServer.
///
/// ```gleam
/// ssr.call(
///   handle: dispatch.handle,
///   state:,
///   module: "shared/messages",
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
  state state: state,
  module module: String,
  msg msg: msg,
  expect expect: fn(response) -> payload,
) -> Result(payload, SsrError) {
  let data = wire.encode_call(module:, request_id: 0, msg:)
  let #(response_bytes, maybe_panic, _state) = handle(state, data)
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

/// Generate a complete HTML document with a pre-rendered body,
/// embedded flags, and a client module import.
///
/// The `title` is HTML-escaped automatically. The `body` is inserted
/// as raw HTML (assumed to be pre-rendered Lustre output). The
/// `client_module` is a JS import path controlled by the developer,
/// not user input — it is not escaped (by design). If you derive this
/// value from external input, you must validate it yourself.
/// The `flags` value is encoded
/// internally via `encode_flags`, producing a base64 string that is
/// safe to embed in a JS string literal.
pub fn document(
  title title: String,
  body body: String,
  flags flags: a,
  client_module client_module: String,
) -> String {
  let encoded_flags = encode_flags(flags)
  "<!doctype html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"utf-8\" />\n  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n  <title>"
  <> escape_html(title)
  <> "</title>\n</head>\n<body>\n  <div id=\"app\">"
  <> body
  <> "</div>\n  <script>window.__LIBERO_FLAGS__ = \""
  <> encoded_flags
  <> "\";</script>\n  <script type=\"module\">\n    import { main } from \""
  <> client_module
  <> "\";\n    main();\n  </script>\n</body>\n</html>"
}

/// Escape HTML special characters to prevent XSS in text content.
fn escape_html(text: String) -> String {
  text
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&#39;")
}
