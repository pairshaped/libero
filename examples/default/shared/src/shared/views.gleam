import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/router.{type Route, Home}

pub type Model {
  Model(route: Route, ping_response: String)
}

pub type Msg {
  UserClickedPing
  NavigateTo(Route)
  NoOp
}

pub fn title(model: Model) -> String {
  case model.route {
    Home -> "libero app"
  }
}

pub fn view(model: Model) -> Element(Msg) {
  case model.route {
    Home -> home_view(model.ping_response)
  }
}

fn home_view(ping_response: String) -> Element(Msg) {
  html.div([], [
    html.h1([], [html.text("Hello from libero")]),
    html.button([event.on_click(UserClickedPing)], [html.text("Ping")]),
    case ping_response {
      "" -> html.p([], [html.text("Click to ping the server.")])
      msg -> html.p([], [html.text("Server says: " <> msg)])
    },
  ])
}
