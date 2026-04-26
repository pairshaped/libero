import gleeunit
import handler
import handler_context

pub fn main() {
  gleeunit.main()
}

pub fn ping_test() {
  let state = handler_context.new()
  let assert #(Ok("pong"), _) = handler.ping(state:)
}
