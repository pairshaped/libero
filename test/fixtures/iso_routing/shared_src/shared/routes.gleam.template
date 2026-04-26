//// Shared route module — must compile and run identically on Erlang and JS.

import gleam/int
import gleam/result
import gleam/uri.{type Uri}

pub type Route {
  Home
  Post(id: Int)
  User(slug: String)
}

pub fn parse_route(uri: Uri) -> Result(Route, Nil) {
  case uri.path_segments(uri.path) {
    [] | ["home"] -> Ok(Home)
    ["posts", id_str] -> int.parse(id_str) |> result.map(Post)
    ["users", slug] -> Ok(User(slug))
    _ -> Error(Nil)
  }
}

pub fn route_to_path(route: Route) -> String {
  case route {
    Home -> "/home"
    Post(id) -> "/posts/" <> int.to_string(id)
    User(slug) -> "/users/" <> slug
  }
}
