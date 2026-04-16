//// Logger type used by generated WebSocket handlers.
////
//// Consumers pass a Logger value into `ws.upgrade` so the
//// generated handler can emit structured log messages without
//// libero needing to know about any particular logging backend.

import gleam/io

pub type Logger {
  Logger(
    debug: fn(String) -> Nil,
    warning: fn(String) -> Nil,
    error: fn(String) -> Nil,
  )
}

/// Default logger that prints everything to stdout via `io.println`.
/// Suitable for examples and local development; replace with a real
/// structured logger in production code.
pub fn default_logger() -> Logger {
  Logger(
    debug: fn(msg) { io.println("[debug] " <> msg) },
    warning: fn(msg) { io.println("[warning] " <> msg) },
    error: fn(msg) { io.println("[error] " <> msg) },
  )
}
