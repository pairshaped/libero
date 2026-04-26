import handler_context.{type HandlerContext}
import shared/types.{type PingError}

pub fn ping(
  handler_ctx handler_ctx: HandlerContext,
) -> #(Result(String, PingError), HandlerContext) {
  #(Ok("pong"), handler_ctx)
}
