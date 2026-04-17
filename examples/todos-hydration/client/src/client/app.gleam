import client/generated/libero/todos as rpc
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import libero/remote_data.{NotAsked, Success}
import libero/wire
import lustre
import lustre/effect
import shared/todos.{
  type Todo, Create, Delete, NotFound, TitleRequired, TodoParams,
  TodosLoaded, Toggle,
}
import shared/views.{
  type Model, type Msg, DeleteClicked, GotPush, InputChanged, Model, Submit,
  ToggleClicked, TodoCreatedMsg, TodoDeletedMsg, TodoToggledMsg, TodosLoadedMsg,
}

// ---- Init ----

pub fn init(flags: Dynamic) -> #(Model, effect.Effect(Msg)) {
  let items = decode_flags(flags)
  let subscribe =
    rpc.update_from_server(handler: fn(raw: Dynamic) {
      GotPush(wire.coerce(raw))
    })
  #(
    Model(items: Success(items), input: "", last_action: NotAsked),
    effect.batch([subscribe]),
  )
}

fn decode_flags(flags: Dynamic) -> List(Todo) {
  let s: String = wire.coerce(flags)
  let assert Ok(etf) = bit_array.base64_decode(s)
  wire.decode(etf)
}

// ---- Effects ----

fn format_todo_error(err: todos.TodoError) -> String {
  case err {
    NotFound -> "Todo not found"
    TitleRequired -> "Title is required"
  }
}

fn create(title: String) -> effect.Effect(Msg) {
  rpc.send_to_server(
    msg: Create(params: TodoParams(title:)),
    on_response: fn(raw) {
      TodoCreatedMsg(remote_data.to_remote(raw: raw, format_domain: format_todo_error))
    },
  )
}

fn toggle(id: Int) -> effect.Effect(Msg) {
  rpc.send_to_server(msg: Toggle(id:), on_response: fn(raw) {
    TodoToggledMsg(remote_data.to_remote(raw: raw, format_domain: format_todo_error))
  })
}

fn delete(id: Int) -> effect.Effect(Msg) {
  rpc.send_to_server(msg: Delete(id:), on_response: fn(raw) {
    TodoDeletedMsg(remote_data.to_remote(raw: raw, format_domain: format_todo_error))
  })
}

// ---- Update ----

pub fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    InputChanged(value) -> #(Model(..model, input: value), effect.none())

    Submit -> {
      case model.input {
        "" -> #(model, effect.none())
        title -> #(
          Model(..model, input: "", last_action: remote_data.Loading),
          create(title),
        )
      }
    }

    ToggleClicked(id) -> #(
      Model(..model, last_action: remote_data.Loading),
      toggle(id),
    )

    DeleteClicked(id) -> #(
      Model(..model, last_action: remote_data.Loading),
      delete(id),
    )

    TodosLoadedMsg(rd) -> #(Model(..model, items: rd), effect.none())

    TodoCreatedMsg(rd) -> #(
      Model(..model, last_action: remote_data.map(rd, fn(_) { Nil })),
      effect.none(),
    )
    TodoToggledMsg(rd) -> #(
      Model(..model, last_action: remote_data.map(rd, fn(_) { Nil })),
      effect.none(),
    )
    TodoDeletedMsg(rd) -> #(
      Model(..model, last_action: remote_data.map(rd, fn(_) { Nil })),
      effect.none(),
    )

    GotPush(TodosLoaded(Ok(items))) -> #(
      Model(..model, items: Success(items)),
      effect.none(),
    )
    GotPush(_) -> #(model, effect.none())
  }
}

// ---- Main ----

@external(javascript, "../client/flags_ffi.mjs", "read_flags")
fn read_flags() -> Dynamic

pub fn main() {
  let app = lustre.application(init, update, views.view)
  let flags = read_flags()
  let assert Ok(_) = lustre.start(app, "#app", flags)
  Nil
}
