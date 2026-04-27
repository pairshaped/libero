import generated/messages as rpc
import generated/ssr.{read_flags}
import gleam/dynamic.{type Dynamic}
import gleam/uri.{type Uri}
import libero/remote_data.{type RemoteData, Success}
import libero/ssr as libero_ssr
import lustre
import lustre/effect.{type Effect}
import lustre/element
import modem
import shared/router
import shared/types.{type PingError}
import shared/views.{
  type Model, type Msg, Model, NavigateTo, NoOp, UserClickedPing,
}

pub type ClientMsg {
  ViewMsg(Msg)
  GotPing(RemoteData(String, PingError))
}

pub fn main() {
  let app = lustre.application(init, update, view_wrap)
  let assert Ok(_) = lustre.start(app, "#app", read_flags())
  Nil
}

fn init(flags: Dynamic) -> #(Model, Effect(ClientMsg)) {
  let model = case libero_ssr.decode_flags(flags) {
    Ok(m) -> m
    Error(_) ->
      panic as "failed to decode SSR flags. Was ssr.boot_script called on the server?"
  }
  #(model, modem.init(on_url_change))
}

fn on_url_change(uri: Uri) -> ClientMsg {
  case router.parse_route(uri) {
    Ok(route) -> ViewMsg(NavigateTo(route))
    Error(_) -> ViewMsg(NoOp)
  }
}

fn update(model: Model, msg: ClientMsg) -> #(Model, Effect(ClientMsg)) {
  case msg {
    ViewMsg(UserClickedPing) -> #(model, rpc.ping(on_response: GotPing))
    ViewMsg(NavigateTo(route)) -> #(Model(..model, route:), effect.none())
    ViewMsg(NoOp) -> #(model, effect.none())
    GotPing(Success(response)) -> #(
      Model(..model, ping_response: response),
      effect.none(),
    )
    GotPing(_) -> #(Model(..model, ping_response: "ping failed"), effect.none())
  }
}

fn view_wrap(model: Model) -> element.Element(ClientMsg) {
  views.view(model) |> element.map(ViewMsg)
}
