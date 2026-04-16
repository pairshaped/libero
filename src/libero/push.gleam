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

/// Register the calling process with a unique client ID.
/// Used for targeted pushes via `send_to_client`.
/// Typically called in the WebSocket on_init with a session-derived ID.
pub fn register(client_id client_id: String) -> Nil {
  pg_join("__client:" <> client_id)
}

/// Unregister the calling process from a client ID.
pub fn unregister(client_id client_id: String) -> Nil {
  pg_leave("__client:" <> client_id)
}

/// Subscribe the calling process to a topic for broadcast pushes.
/// The process will receive `{libero_push, BitArray}` messages
/// when `send_to_clients` is called for this topic.
pub fn join(topic topic: String) -> Nil {
  pg_join(topic)
}

/// Unsubscribe the calling process from a topic.
pub fn leave(topic topic: String) -> Nil {
  pg_leave(topic)
}

/// Send a message to a specific client by ID.
pub fn send_to_client(
  client_id client_id: String,
  module module: String,
  msg msg: a,
) -> Nil {
  let frame = wire.tag_push(module:, msg:)
  pg_send(topic: "__client:" <> client_id, frame:)
}

/// Send a message to all clients subscribed to a topic.
pub fn send_to_clients(
  topic topic: String,
  module module: String,
  msg msg: a,
) -> Nil {
  let frame = wire.tag_push(module:, msg:)
  pg_send(topic:, frame:)
}

// -- Erlang FFI --

@external(erlang, "libero_push_ffi", "ensure_started")
fn ensure_started() -> Nil

@external(erlang, "libero_push_ffi", "pg_join")
fn pg_join(topic: String) -> Nil

@external(erlang, "libero_push_ffi", "pg_leave")
fn pg_leave(topic: String) -> Nil

@external(erlang, "libero_push_ffi", "pg_send")
fn pg_send(topic topic: String, frame frame: BitArray) -> Nil
