import handler_context.{type HandlerContext}
import shared/types.{type PingError}

// Handlers may use either return shape:
//
//   pub fn ping(
//     handler_ctx handler_ctx: HandlerContext,
//   ) -> #(Result(String, PingError), HandlerContext) {
//     #(Ok("pong"), handler_ctx)
//   }
//
// Use the tuple form when the handler emits a NEW HandlerContext (login
// flows that swap the session, anything that mutates state). Otherwise
// return `Result(_, _)` directly: libero's generated dispatch threads
// the inbound context through unchanged.
pub fn ping(
  handler_ctx _handler_ctx: HandlerContext,
) -> Result(String, PingError) {
  Ok("pong")
}
