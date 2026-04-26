import gleam/uri.{type Uri}

pub type Route {
  Home
}

pub fn parse_route(uri: Uri) -> Result(Route, Nil) {
  case uri.path_segments(uri.path) {
    [] -> Ok(Home)
    _ -> Error(Nil)
  }
}

pub fn route_to_path(route: Route) -> String {
  case route {
    Home -> "/"
  }
}
