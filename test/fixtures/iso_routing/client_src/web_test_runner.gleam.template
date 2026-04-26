//// Compiles to JS and runs the same parse_route assertions.
//// On any failure, panics — `gleam run` exits non-zero. On success, prints "OK".

import gleam/io
import gleam/option
import gleam/uri.{type Uri, Uri}
import shared/routes.{Home, Post, User}

fn make_uri(path: String) -> Uri {
  Uri(
    scheme: option.None,
    userinfo: option.None,
    host: option.None,
    port: option.None,
    path:,
    query: option.None,
    fragment: option.None,
  )
}

pub fn main() {
  let assert Ok(Home) = routes.parse_route(make_uri("/home"))
  let assert Ok(Home) = routes.parse_route(make_uri(""))
  let assert Ok(Post(42)) = routes.parse_route(make_uri("/posts/42"))
  let assert Ok(User("alice")) = routes.parse_route(make_uri("/users/alice"))
  let assert Error(Nil) = routes.parse_route(make_uri("/no-such-thing"))
  let assert Error(Nil) = routes.parse_route(make_uri("/posts/notanumber"))

  // route_to_path → parse_route round trips (parity with BEAM tests)
  let assert "/home" = routes.route_to_path(Home)
  let assert "/posts/7" = routes.route_to_path(Post(7))
  let assert "/users/bob" = routes.route_to_path(User("bob"))
  let assert Ok(Home) = routes.parse_route(make_uri(routes.route_to_path(Home)))
  let assert Ok(Post(7)) =
    routes.parse_route(make_uri(routes.route_to_path(Post(7))))
  let assert Ok(User("bob")) =
    routes.parse_route(make_uri(routes.route_to_path(User("bob"))))

  io.println("OK")
}
