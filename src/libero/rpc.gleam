//// Client-side send machinery.
////
//// `send` is the entry point used by libero-generated client stubs.
//// It takes the WebSocket URL, the module name, the typed `ClientMsg`
//// variant, and a callback to wrap the server's response into a
//// Lustre Msg.
////
//// The JS FFI (rpc_ffi.mjs) opens the WebSocket lazily on first call
//// and caches the connection. Sends issued before the socket is open
//// are queued and flushed on the open event. Responses are matched
//// to sends by request ID.
////
//// Developers don't usually call this module directly. They import
//// the per-module stubs the libero generator writes into their
//// client package, and those stubs delegate here.

import gleam/dynamic.{type Dynamic}
import lustre/effect.{type Effect}

/// Send a typed `ClientMsg` value to the server via WebSocket and
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

/// Handle server-initiated push messages on a module.
/// When the server pushes a typed message without a prior request,
/// the callback wraps it into a Lustre Msg for dispatch.
pub fn update_from_server(
  module module: String,
  handler handler: fn(Dynamic) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    ffi_register_push(module:, callback: fn(raw) { dispatch(handler(raw)) })
  })
}

// nolint: avoid_panic, discarded_result -- JS-only @external; Erlang fallback is unreachable
@external(javascript, "./rpc_ffi.mjs", "registerPushHandler")
fn ffi_register_push(
  module module: String,
  callback callback: fn(Dynamic) -> Nil,
) -> Nil {
  let _ = module
  let _ = callback
  panic as "libero/rpc is a JavaScript-only module, unreachable on Erlang target"
}

// nolint: avoid_panic, discarded_result -- JS-only @external; Erlang fallback is unreachable
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
