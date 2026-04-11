//// Client-side RPC machinery.
////
//// `call_by_name` is the low-level entrypoint used by Libero-generated
//// stubs. It takes the WebSocket URL, the wire name, the args, and a
//// wrap callback that produces the Lustre message to dispatch when
//// the response arrives.
////
//// The JS FFI (rpc_ffi.mjs) auto-opens the WebSocket on first call
//// and caches the connection. Calls issued before the socket is open
//// are queued and flushed on the open event.
////
//// Developers don't usually call this module directly. They import
//// the per-module stubs the Libero generator writes into their
//// client package, and those stubs internally delegate here.

import gleam/dynamic.{type Dynamic}
import lustre/effect.{type Effect}

/// Invoke a server RPC by wire name, with typed args and a wrap
/// callback. Called by generated stubs.
///
/// The `url` is read from a generated `rpc_config` module in the
/// consumer's client package, not from this library, so each
/// consumer can configure their own WebSocket endpoint.
pub fn call_by_name(
  url url: String,
  name name: String,
  args args: args,
  wrap wrap: fn(result) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    ffi_call(url: url, name: name, args: args, on_response: fn(dyn) {
      dispatch(wrap(unsafe_coerce(dyn)))
    })
  })
}

// The externals below have Gleam fallback bodies that panic. On the
// JavaScript target the body is ignored and the FFI implementation
// in rpc_ffi.mjs is called. On the Erlang target the body is used,
// but this module is JS-only in practice (server code never imports
// libero/rpc) so the panic is unreachable in a well-formed project.
// The fallback exists solely to keep lib/libero cross-target
// compilable.

@external(javascript, "./rpc_ffi.mjs", "call")
fn ffi_call(
  url url: String,
  name name: String,
  args args: args,
  on_response on_response: fn(Dynamic) -> Nil,
) -> Nil {
  let _ = url
  let _ = name
  let _ = args
  let _ = on_response
  panic as "libero/rpc is a JavaScript-only module, unreachable on Erlang target"
}

@external(javascript, "./rpc_ffi.mjs", "identity")
fn unsafe_coerce(value: Dynamic) -> a {
  let _ = value
  panic as "libero/rpc is a JavaScript-only module, unreachable on Erlang target"
}
