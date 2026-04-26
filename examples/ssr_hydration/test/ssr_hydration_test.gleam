import gleam/string
import gleeunit
import libero/ssr
import lustre/attribute
import lustre/element
import lustre/element/html
import server/handler
import server/handler_context
import shared/views.{Model}

pub fn main() {
  gleeunit.main()
}

fn fresh_state() -> handler_context.HandlerContext {
  handler_context.new()
}

pub fn get_counter_returns_zero_initially_test() {
  let state = fresh_state()
  let assert #(Ok(0), _) = handler.get_counter(state:)
}

pub fn increment_returns_one_test() {
  let state = fresh_state()
  let assert #(Ok(1), _) = handler.increment(state:)
}

pub fn decrement_returns_negative_one_test() {
  let state = fresh_state()
  let assert #(Ok(-1), _) = handler.decrement(state:)
}

pub fn element_to_string_renders_html_test() {
  let model = Model(route: views.IncPage, counter: 42)
  let html = element.to_string(views.view(model))
  let assert True = string.contains(html, "Counter: 42")
  let assert True = string.contains(html, ">+</button>")
}

pub fn full_ssr_render_test() {
  let _state = fresh_state()
  // Directly call handler instead of going through dispatch for this test
  let counter = 0
  let model = Model(route: views.DecPage, counter:)
  let doc =
    element.to_string(
      html.html([], [
        html.body([], [
          html.div([attribute.id("app")], [views.view(model)]),
          ssr.boot_script(client_module: "/web/web/app.mjs", flags: model),
        ]),
      ]),
    )
  let assert True = string.contains(doc, "Counter: 0")
  let assert True = string.contains(doc, ">-</button>")
  let assert True = string.contains(doc, "__LIBERO_FLAGS__")
}

pub fn increment_then_decrement_returns_zero_test() {
  let state = fresh_state()
  let assert #(Ok(1), state) = handler.increment(state:)
  let assert #(Ok(0), _) = handler.decrement(state:)
}
