import generated/messages as rpc
import generated/ssr.{read_flags}
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/uri.{type Uri}
import libero/remote_data.{type RpcData, Success}
import libero/ssr as libero_ssr
import lustre
import lustre/effect.{type Effect}
import lustre/element
import modem
import shared/router
import shared/types.{type Item, type ItemError, ItemParams}
import shared/views.{
  type Model, type Msg, Model, NavigateTo, NoOp, UserDeleted, UserSubmittedTitle,
  UserToggled, UserTyped,
}

pub type ClientMsg {
  ViewMsg(Msg)
  GotItems(RpcData(List(Item), ItemError))
  GotCreated(RpcData(Item, ItemError))
  GotToggled(RpcData(Item, ItemError))
  GotDeleted(RpcData(Int, ItemError))
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
    ViewMsg(NavigateTo(route)) -> #(Model(..model, route:), effect.none())
    ViewMsg(NoOp) -> #(model, effect.none())
    ViewMsg(UserTyped(value:)) -> #(Model(..model, input: value), effect.none())
    ViewMsg(UserSubmittedTitle) ->
      case model.input {
        "" -> #(model, effect.none())
        title -> #(
          Model(..model, input: ""),
          rpc.create_item(params: ItemParams(title:), on_response: GotCreated),
        )
      }
    ViewMsg(UserToggled(id:)) -> #(
      model,
      rpc.toggle_item(id:, on_response: GotToggled),
    )
    ViewMsg(UserDeleted(id:)) -> #(
      model,
      rpc.delete_item(id:, on_response: GotDeleted),
    )
    GotItems(rd) -> #(Model(..model, items: rd), effect.none())
    GotCreated(Success(item)) -> #(
      Model(
        ..model,
        items: remote_data.map(data: model.items, transform: fn(items) {
          list.append(items, [item])
        }),
      ),
      effect.none(),
    )
    GotToggled(Success(updated)) -> #(
      Model(
        ..model,
        items: remote_data.map(data: model.items, transform: fn(items) {
          list.map(items, fn(it) {
            case it.id == updated.id {
              True -> updated
              False -> it
            }
          })
        }),
      ),
      effect.none(),
    )
    GotDeleted(Success(id)) -> #(
      Model(
        ..model,
        items: remote_data.map(data: model.items, transform: fn(items) {
          list.filter(items, fn(it) { it.id != id })
        }),
      ),
      effect.none(),
    )
    GotCreated(_) -> #(model, effect.none())
    GotToggled(_) -> #(model, effect.none())
    GotDeleted(_) -> #(model, effect.none())
  }
}

fn view_wrap(model: Model) -> element.Element(ClientMsg) {
  views.view(model) |> element.map(ViewMsg)
}
