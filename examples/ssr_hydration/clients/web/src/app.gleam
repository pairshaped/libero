//// Client app: hydrates SSR-rendered HTML, handles RPC and routing.

import generated/messages as rpc
import generated/ssr
import gleam/dynamic.{type Dynamic}
import libero/remote_data.{type RemoteData, Success}
import libero/ssr as libero_ssr
import lustre
import lustre/effect.{type Effect}
import router
import shared/views.{
  type Model, type Msg, CounterChanged, DecPage, IncPage, Model, NavigateTo,
  UserClickedAction,
}

pub fn main() {
  let app = lustre.application(init, update, views.view)
  let flags = ssr.read_flags()
  let assert Ok(_) = lustre.start(app, "#app", flags)
  Nil
}

fn init(flags: Dynamic) -> #(Model, Effect(Msg)) {
  let counter = case libero_ssr.decode_flags(flags) {
    Ok(n) -> n
    Error(_) -> 0
  }
  let route = views.route_from_path(router.get_pathname())
  #(
    Model(route:, counter:),
    effect.batch([
      router.listen_nav_clicks(fn(path) {
        NavigateTo(views.route_from_path(path))
      }),
      router.on_popstate(fn(path) { NavigateTo(views.route_from_path(path)) }),
    ]),
  )
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    // Send increment or decrement RPC based on current route.
    // The generated stub handles wire encoding and response decoding.
    // on_response wraps the RemoteData result in our CounterChanged msg.
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
    NavigateTo(route) -> #(
      Model(..model, route:),
      router.push_url(views.route_to_path(route)),
    )
    CounterChanged(n) -> #(Model(..model, counter: n), effect.none())
  }
}

// Extract the counter value from RemoteData, defaulting to 0 on failure.
fn unwrap_counter(rd: RemoteData(Int, Nil)) -> Int {
  case rd {
    Success(n) -> n
    _ -> 0
  }
}
