import gleam/string
import gleeunit
import libero/ssr
import lustre/element
import server/generated/dispatch
import server/handler
import server/shared_state
import shared/messages.{CounterUpdated, Decrement, GetCounter, Increment}
import shared/views.{Model}

pub fn main() {
  gleeunit.main()
}

fn fresh_state() -> shared_state.SharedState {
  shared_state.new()
}

pub fn get_counter_returns_zero_initially_test() {
  let state = fresh_state()
  let assert Ok(#(CounterUpdated(Ok(0)), _)) =
    handler.update_from_client(msg: GetCounter, state:)
}

pub fn increment_returns_one_test() {
  let state = fresh_state()
  let assert Ok(#(CounterUpdated(Ok(1)), _)) =
    handler.update_from_client(msg: Increment, state:)
}

pub fn decrement_returns_negative_one_test() {
  let state = fresh_state()
  let assert Ok(#(CounterUpdated(Ok(-1)), _)) =
    handler.update_from_client(msg: Decrement, state:)
}

pub fn ssr_call_returns_msg_from_server_test() {
  let state = fresh_state()
  let _ = dispatch.ensure_atoms()
  let assert Ok(messages.CounterUpdated(Ok(0))) =
    ssr.call(
      handle: dispatch.handle,
      state:,
      module: "shared/messages",
      msg: GetCounter,
    )
}

pub fn element_to_string_renders_html_test() {
  let model = Model(route: views.IncPage, counter: 42)
  let html = element.to_string(views.view(model))
  let assert True = string.contains(html, "Counter: 42")
  let assert True = string.contains(html, ">+</button>")
}

pub fn full_ssr_render_test() {
  let state = fresh_state()
  let _ = dispatch.ensure_atoms()
  let assert Ok(messages.CounterUpdated(Ok(0))) =
    ssr.call(
      handle: dispatch.handle,
      state:,
      module: "shared/messages",
      msg: GetCounter,
    )
  let model = Model(route: views.DecPage, counter: 0)
  let body = element.to_string(views.view(model))
  let flags = ssr.encode_flags(0)
  let doc =
    ssr.document(
      title: "Counter",
      body:,
      flags:,
      client_module: "/web/web/app.mjs",
    )
  let assert True = string.contains(doc, "Counter: 0")
  let assert True = string.contains(doc, ">-</button>")
  let assert True = string.contains(doc, "__LIBERO_FLAGS__")
}

pub fn increment_then_decrement_returns_zero_test() {
  let state = fresh_state()
  let assert Ok(#(CounterUpdated(Ok(1)), state)) =
    handler.update_from_client(msg: Increment, state:)
  let assert Ok(#(CounterUpdated(Ok(0)), _)) =
    handler.update_from_client(msg: Decrement, state:)
}
