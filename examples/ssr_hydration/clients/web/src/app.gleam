//// Client app: hydrates SSR-rendered HTML, handles RPC and routing via modem.

import generated/messages as rpc
import gleam/dynamic.{type Dynamic}
import gleam/uri.{type Uri}
import libero/remote_data.{type RemoteData, Success}
import libero/ssr as libero_ssr
import lustre
import lustre/effect.{type Effect}
import modem
import shared/views.{
  type Model, type Msg, CounterChanged, DecPage, IncPage, Model, NavigateTo,
  NoOp, UserClickedAction,
}

pub fn main() {
  let app = lustre.application(init, update, views.view)
  let assert Ok(_) = lustre.start(app, "#app", get_flags())
  Nil
}

fn init(flags: Dynamic) -> #(Model, Effect(Msg)) {
  let model = case libero_ssr.decode_flags(flags) {
    Ok(m) -> m
    Error(_) ->
      panic as "failed to decode SSR flags — was ssr.boot_script called on the server?"
  }
  #(model, modem.init(on_url_change))
}

fn on_url_change(uri: Uri) -> Msg {
  case views.parse_route(uri) {
    Ok(route) -> NavigateTo(route)
    // Modem fires on every same-origin link click + popstate. Bad URLs
    // shouldn't reach here in this app, but if they do we ignore them
    // (NoOp) rather than crash the runtime. To handle them explicitly,
    // widen parse_route or add a fallback Route variant.
    Error(_) -> NoOp
  }
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UserClickedAction -> {
      let effect = case model.route {
        IncPage ->
          rpc.increment(on_response: fn(rd) {
            CounterChanged(unwrap_counter(rd))
          })
        DecPage ->
          rpc.decrement(on_response: fn(rd) {
            CounterChanged(unwrap_counter(rd))
          })
      }
      #(model, effect)
    }
    NavigateTo(route) -> #(Model(..model, route:), effect.none())
    CounterChanged(n) -> #(Model(..model, counter: n), effect.none())
    NoOp -> #(model, effect.none())
  }
}

fn unwrap_counter(rd: RemoteData(Int, Nil)) -> Int {
  case rd {
    Success(n) -> n
    _ -> 0
  }
}

@external(javascript, "./flags_ffi.mjs", "getFlags")
fn get_flags() -> Dynamic {
  panic as "get_flags requires a browser"
}
