//// Client app: hydrates SSR-rendered HTML, handles RPC and routing.

import generated/messages as rpc
import generated/ssr
import gleam/dynamic.{type Dynamic}
import libero/remote_data
import libero/ssr as libero_ssr
import lustre
import lustre/effect.{type Effect}
import router
import shared/messages.{Decrement, Increment}
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
    UserClickedAction -> {
      let rpc_msg = case model.route {
        IncPage -> Increment
        DecPage -> Decrement
      }
      #(
        model,
        rpc.send_to_server(msg: rpc_msg, on_response: fn(raw) {
          CounterChanged(decode_counter(raw))
        }),
      )
    }
    NavigateTo(route) -> #(
      Model(..model, route:),
      router.push_url(views.route_to_path(route)),
    )
    CounterChanged(n) -> #(Model(..model, counter: n), effect.none())
  }
}

fn decode_counter(raw: Dynamic) -> Int {
  let rd = remote_data.to_remote(raw:, format_domain: fn(_) { "error" })
  case rd {
    remote_data.Success(n) -> n
    _ -> 0
  }
}
