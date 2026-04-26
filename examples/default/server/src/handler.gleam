import handler_context.{type HandlerContext}
import shared/types.{type PingError}

pub fn ping(
  state state: HandlerContext,
) -> #(Result(String, PingError), HandlerContext) {
  #(Ok("pong"), state)
}
