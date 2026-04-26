//// Cross-target views, model, and routing types.
//// Compiles to both Erlang (for SSR) and JavaScript (for client).

import gleam/int
import gleam/uri.{type Uri}
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
      ..case active {
        True -> [attribute.class("active")]
        False -> []
      }
    ],
    [html.text(label)],
  )
}

/// Parse a URI to a Route. Used by both the server (to route requests)
/// and the client (modem hands us a Uri on navigation events).
/// Cross-target: compiles to BEAM and JS.
pub fn parse_route(uri: Uri) -> Result(Route, Nil) {
  case uri.path_segments(uri.path) {
    [] | ["inc"] -> Ok(IncPage)
    ["dec"] -> Ok(DecPage)
    _ -> Error(Nil)
  }
}

pub fn route_to_path(route: Route) -> String {
  case route {
    IncPage -> "/inc"
    DecPage -> "/dec"
  }
}
