//// Helpers for server-side rendering with Libero.
////
//// Server-side: call a dispatch handler directly, encode flags for
//// the HTML document, and render the full page shell.
////
//// Client-side: read and decode flags embedded by the server.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}
import gleam/result
import libero/error.{type PanicInfo}
import libero/wire

pub type SsrError {
  BadResponse
  DispatchError
  BadFlags
}

/// Call a dispatch handler directly on the server, returning the
/// decoded response payload. Encodes the call envelope, invokes
/// the handler, strips the wire framing, and unwraps the result.
pub fn call(
  handle handle: fn(state, BitArray) -> #(BitArray, Option(PanicInfo), state),
  state state: state,
  module module: String,
  msg msg: msg,
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
          let decoded: Result(payload, _) = wire.decode(etf)
          case decoded {
            Ok(payload) -> Ok(payload)
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
  let encoded: String = wire.coerce(flags)
  bit_array.base64_decode(encoded)
  |> result.map(wire.decode)
  |> result.replace_error(BadFlags)
}

/// Generate a complete HTML document with a pre-rendered body,
/// embedded flags, and a client module import.
pub fn document(
  title title: String,
  body body: String,
  flags flags: String,
  client_module client_module: String,
) -> String {
  "<!doctype html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"utf-8\" />\n  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n  <title>"
  <> title
  <> "</title>\n</head>\n<body>\n  <div id=\"app\">"
  <> body
  <> "</div>\n  <script>window.__LIBERO_FLAGS__ = \""
  <> flags
  <> "\";</script>\n  <script type=\"module\">\n    import { main } from \""
  <> client_module
  <> "\";\n    main();\n  </script>\n</body>\n</html>"
}
