import gleeunit
import handler
import handler_context

pub fn main() {
  gleeunit.main()
}

pub fn ping_test() {
  let handler_ctx = handler_context.new()
  let assert #(Ok("pong"), _) = handler.ping(handler_ctx:)
}
