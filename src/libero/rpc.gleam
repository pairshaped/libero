//// Client-side send machinery.
////
//// `send` is the entry point used by libero-generated client stubs.
//// It takes the WebSocket URL, the module name, the typed MsgFromClient
//// message, and a callback to wrap the server's response into a
//// Lustre Msg.
////
//// The JS FFI (rpc_ffi.mjs) opens the WebSocket lazily on first call
//// and caches the connection. Sends issued before the socket is open
//// are queued and flushed on the open event. Responses are matched
//// to sends in FIFO order.
////
//// Developers don't usually call this module directly. They import
//// the per-module stubs the libero generator writes into their
//// client package, and those stubs delegate here.

import gleam/dynamic.{type Dynamic}
import lustre/effect.{type Effect}

/// Send a typed MsgFromClient message to the server via WebSocket and
/// deliver the server's response back to the Lustre update loop.
///
/// The `on_response` callback wraps the decoded response (a Dynamic
/// value reconstructed from ETF) into a Lustre Msg so it can be
/// dispatched through `update`.
pub fn send(
  url url: String,
  module module: String,
  msg msg: a,
  on_response on_response: fn(Dynamic) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    ffi_send(url:, module:, msg:, on_response: fn(raw) {
      dispatch(on_response(raw))
    })
  })
}

@external(javascript, "./rpc_ffi.mjs", "send")
fn ffi_send(
  url url: String,
  module module: String,
  msg msg: a,
  on_response on_response: fn(Dynamic) -> Nil,
) -> Nil {
  let _ = url
  let _ = module
  let _ = msg
  let _ = on_response
  panic as "libero/rpc is a JavaScript-only module, unreachable on Erlang target"
}
