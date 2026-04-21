//// Browser routing helpers: pushState, pathname reading, click interception.

import lustre/effect.{type Effect}

/// Read the current pathname from window.location.
@external(javascript, "./router_ffi.mjs", "getPathname")
pub fn get_pathname() -> String {
  panic as "get_pathname requires a browser"
}

/// Push a URL to the history stack without reloading.
pub fn push_url(path: String) -> Effect(msg) {
  effect.from(fn(_dispatch) { do_push_url(path) })
}

@external(javascript, "./router_ffi.mjs", "pushUrl")
fn do_push_url(_path: String) -> Nil {
  panic as "push_url requires a browser"
}

/// Listen for clicks on elements with data-navlink attribute.
/// Prevents default, reads the href, and dispatches the mapped message.
pub fn listen_nav_clicks(on_click: fn(String) -> msg) -> Effect(msg) {
  effect.from(fn(dispatch) {
    do_listen_nav_clicks(fn(path) { dispatch(on_click(path)) })
  })
}

@external(javascript, "./router_ffi.mjs", "listenNavClicks")
fn do_listen_nav_clicks(_callback: fn(String) -> Nil) -> Nil {
  panic as "listen_nav_clicks requires a browser"
}

/// Listen for popstate events (back/forward button).
pub fn on_popstate(on_change: fn(String) -> msg) -> Effect(msg) {
  effect.from(fn(dispatch) {
    do_on_popstate(fn(path) { dispatch(on_change(path)) })
  })
}

@external(javascript, "./router_ffi.mjs", "onPopstate")
fn do_on_popstate(_callback: fn(String) -> Nil) -> Nil {
  panic as "on_popstate requires a browser"
}
