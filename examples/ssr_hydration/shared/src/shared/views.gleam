//// Cross-target views, model, and routing types.
//// Compiles to both Erlang (for SSR) and JavaScript (for client).

import gleam/int
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub type Route {
  IncPage
  DecPage
}

pub type Model {
  Model(route: Route, counter: Int)
}

/// Msg contains only what views can emit: user actions and navigation.
/// No Dynamic, no RemoteData, no JS-only types.
pub type Msg {
  UserClickedAction
  NavigateTo(Route)
  CounterChanged(Int)
}

pub fn view(model: Model) -> Element(Msg) {
  html.div([], [
    nav(model.route),
    html.p([], [html.text("Counter: " <> int.to_string(model.counter))]),
    case model.route {
      IncPage ->
        html.button([event.on_click(UserClickedAction)], [html.text("+")])
      DecPage ->
        html.button([event.on_click(UserClickedAction)], [html.text("-")])
    },
  ])
}

fn nav(current: Route) -> Element(Msg) {
  html.nav([], [
    nav_link("/inc", "Increment", current == IncPage),
    html.text(" | "),
    nav_link("/dec", "Decrement", current == DecPage),
  ])
}

fn nav_link(href: String, label: String, active: Bool) -> Element(Msg) {
  html.a(
    [
      attribute.href(href),
      attribute.attribute("data-navlink", ""),
      ..case active {
        True -> [attribute.class("active")]
        False -> []
      }
    ],
    [html.text(label)],
  )
}

pub fn route_from_path(path: String) -> Route {
  case path {
    "/dec" -> DecPage
    _ -> IncPage
  }
}

pub fn route_to_path(route: Route) -> String {
  case route {
    IncPage -> "/inc"
    DecPage -> "/dec"
  }
}
