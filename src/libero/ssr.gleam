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
/// strips the wire framing, and passes the `MsgFromServer` response
/// through the `expect` function to extract the desired value.
///
/// The `expect` parameter works like Elm's `Http.expect` — you tell
/// the call how to unwrap the response variant into the value you
/// actually want:
///
/// ```gleam
/// ssr.call(
///   handle: dispatch.handle,
///   state:,
///   module: "shared/messages",
///   msg: GetCounter,
///   expect: fn(resp) {
///     let assert CounterUpdated(Ok(n)) = resp
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
  let data = wire.encode_call(module:, msg:)
  let #(response_bytes, maybe_panic, _state) = handle(state, data)
  case maybe_panic {
    option.Some(_) -> Error(DispatchError)
    option.None ->
      case response_bytes {
        <<_tag, etf:bytes>> -> {
          // dispatch encodes Ok(MsgFromServer_variant) or Error(RpcError).
          // wire.decode returns the Gleam value directly via coerce.
          let decoded: Result(response, _) = wire.decode(etf)
          case decoded {
            Ok(response) -> Ok(expect(response))
            Error(_) -> Error(DispatchError)
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
/// not user input — it is not escaped.
pub fn document(
  title title: String,
  body body: String,
  flags flags: String,
  client_module client_module: String,
) -> String {
  "<!doctype html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"utf-8\" />\n  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n  <title>"
  <> escape_html(title)
  <> "</title>\n</head>\n<body>\n  <div id=\"app\">"
  <> body
  <> "</div>\n  <script>window.__LIBERO_FLAGS__ = \""
  <> flags
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
