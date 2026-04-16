//// Server-side push support.
////
//// Allows the server to send MsgFromServer messages to connected
//// WebSocket clients without a prior request. Uses BEAM pg (process
//// groups) for topic-based subscriptions.
////
//// Import this module only if your app needs server push.
//// If unused, no processes or groups are created.

import libero/wire

/// Ensure the push pg scope is started. Call once at server boot.
/// Idempotent — safe to call multiple times.
pub fn init() -> Nil {
  ensure_started()
}

/// Subscribe the calling process to a topic. The process will
/// receive `{libero_push, BitArray}` messages when a push is
/// broadcast to this topic.
pub fn join(topic topic: String) -> Nil {
  pg_join(topic)
}

/// Unsubscribe the calling process from a topic.
pub fn leave(topic topic: String) -> Nil {
  pg_leave(topic)
}

/// Broadcast a message to all processes subscribed to a topic.
/// Each subscriber receives a `{libero_push, BitArray}` message
/// containing the tagged push frame ready to send over WebSocket.
pub fn broadcast(
  topic topic: String,
  module module: String,
  msg msg: a,
) -> Nil {
  let frame = wire.tag_push(module:, msg:)
  pg_broadcast(topic:, frame:)
}

// -- Erlang FFI --

@external(erlang, "libero_push_ffi", "ensure_started")
fn ensure_started() -> Nil

@external(erlang, "libero_push_ffi", "pg_join")
fn pg_join(topic: String) -> Nil

@external(erlang, "libero_push_ffi", "pg_leave")
fn pg_leave(topic: String) -> Nil

@external(erlang, "libero_push_ffi", "pg_broadcast")
fn pg_broadcast(topic topic: String, frame frame: BitArray) -> Nil
