import gleam/option
import gleam/uri.{type Uri, Uri}
import gleeunit
import shared/routes.{Home, Post, User}

pub fn main() {
  gleeunit.main()
}

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

pub fn parse_home_test() {
  let assert Ok(Home) = routes.parse_route(make_uri("/home"))
  let assert Ok(Home) = routes.parse_route(make_uri(""))
}

pub fn parse_post_test() {
  let assert Ok(Post(42)) = routes.parse_route(make_uri("/posts/42"))
}

pub fn parse_user_test() {
  let assert Ok(User("alice")) = routes.parse_route(make_uri("/users/alice"))
}

pub fn parse_unknown_test() {
  let assert Error(Nil) = routes.parse_route(make_uri("/no-such-thing"))
}

pub fn parse_post_invalid_id_test() {
  let assert Error(Nil) = routes.parse_route(make_uri("/posts/notanumber"))
}

pub fn route_to_path_roundtrip_test() {
  let assert "/home" = routes.route_to_path(Home)
  let assert "/posts/7" = routes.route_to_path(Post(7))
  let assert "/users/bob" = routes.route_to_path(User("bob"))
  let assert Ok(Home) = routes.parse_route(make_uri(routes.route_to_path(Home)))
  let assert Ok(Post(7)) =
    routes.parse_route(make_uri(routes.route_to_path(Post(7))))
  let assert Ok(User("bob")) =
    routes.parse_route(make_uri(routes.route_to_path(User("bob"))))
}
