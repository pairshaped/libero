import client/generated/libero/todos as rpc
import gleam/dynamic.{type Dynamic}
import gleam/list
import libero/remote_data.{
  type RemoteData, type RpcFailure, Failure, Loading, NotAsked, Success,
  to_remote,
}
import libero/wire
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/todos.{
  type MsgFromServer, type Todo, Create, Delete, LoadAll, NotFound,
  TitleRequired, TodoParams, TodosLoaded, Toggle,
}

// ---- Model ----
//
// `items` uses RemoteData so the view can show "loading" before the
// initial fetch resolves and a typed error if it fails. Mutating
// actions (Create, Toggle, Delete) update `last_action` so the view
// can show optimistic state or surface the most recent error - whichever
// is most useful for the demo. Real apps typically thread the action's
// RemoteData through the field whose UI it controls (e.g. a per-row
// `delete_status` to disable individual delete buttons).

pub type Model {
  Model(
    items: RemoteData(List(Todo), RpcFailure),
    input: String,
    last_action: RemoteData(Nil, RpcFailure),
  )
}

// ---- Msg ----

pub type Msg {
  InputChanged(String)
  Submit
  ToggleClicked(Int)
  DeleteClicked(Int)
  TodosLoadedMsg(RemoteData(List(Todo), RpcFailure))
  TodoCreatedMsg(RemoteData(Todo, RpcFailure))
  TodoToggledMsg(RemoteData(Todo, RpcFailure))
  TodoDeletedMsg(RemoteData(Int, RpcFailure))
  GotPush(MsgFromServer)
}

// ---- Init ----

pub fn init(_flags: Nil) -> #(Model, Effect(Msg)) {
  let subscribe =
    rpc.update_from_server(handler: fn(raw: Dynamic) {
      GotPush(wire.coerce(raw))
    })
  #(
    Model(items: Loading, input: "", last_action: NotAsked),
    effect.batch([load_all(), subscribe]),
  )
}

// ---- Effects ----

fn load_all() -> Effect(Msg) {
  rpc.send_to_server(msg: LoadAll, on_response: fn(raw) {
    TodosLoadedMsg(to_remote(raw, format_todo_error))
  })
}

fn create(title: String) -> Effect(Msg) {
  rpc.send_to_server(
    msg: Create(params: TodoParams(title:)),
    on_response: fn(raw) { TodoCreatedMsg(to_remote(raw, format_todo_error)) },
  )
}

fn toggle(id: Int) -> Effect(Msg) {
  rpc.send_to_server(msg: Toggle(id:), on_response: fn(raw) {
    TodoToggledMsg(to_remote(raw, format_todo_error))
  })
}

fn delete(id: Int) -> Effect(Msg) {
  rpc.send_to_server(msg: Delete(id:), on_response: fn(raw) {
    TodoDeletedMsg(to_remote(raw, format_todo_error))
  })
}

fn format_todo_error(err: todos.TodoError) -> String {
  case err {
    NotFound -> "Todo not found"
    TitleRequired -> "Title is required"
  }
}

// ---- Update ----

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    InputChanged(value) -> #(Model(..model, input: value), effect.none())

    Submit -> {
      case model.input {
        "" -> #(model, effect.none())
        title -> #(
          Model(..model, input: "", last_action: Loading),
          create(title),
        )
      }
    }

    ToggleClicked(id) -> #(Model(..model, last_action: Loading), toggle(id))

    DeleteClicked(id) -> #(Model(..model, last_action: Loading), delete(id))

    // Initial load result.
    TodosLoadedMsg(rd) -> #(Model(..model, items: rd), effect.none())

    // Mutating actions: collapse Success into Nil because the push
    // message will refresh `items`. We keep the RemoteData state for
    // the view to render disabled buttons or surface a domain error.
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

    // Server-pushed update (e.g. another client mutated the list).
    // Push messages keep the MsgFromServer envelope so we can route by
    // variant.
    GotPush(TodosLoaded(Ok(items))) -> #(
      Model(..model, items: Success(items)),
      effect.none(),
    )
    GotPush(_) -> #(model, effect.none())
  }
}

// ---- View ----

pub fn view(model: Model) -> Element(Msg) {
  html.div(
    [
      attribute.styles([
        #("max-width", "400px"),
        #("margin", "2em auto"),
        #("font-family", "system-ui, sans-serif"),
      ]),
    ],
    [
      html.h1([], [element.text("Todos")]),
      view_input(model),
      view_action_status(model.last_action),
      view_items(model.items),
    ],
  )
}

fn view_input(model: Model) -> Element(Msg) {
  html.form(
    [
      event.on_submit(fn(_formdata) { Submit }),
      attribute.styles([#("display", "flex"), #("gap", "0.5em")]),
    ],
    [
      html.input([
        attribute.value(model.input),
        attribute.placeholder("What needs to be done?"),
        event.on_input(InputChanged),
        attribute.style("flex", "1"),
        attribute.style("padding", "0.5em"),
      ]),
      html.button(
        [attribute.type_("submit"), attribute.style("padding", "0.5em 1em")],
        [element.text("Add")],
      ),
    ],
  )
}

fn view_action_status(rd: RemoteData(Nil, RpcFailure)) -> Element(Msg) {
  case rd {
    Failure(err) ->
      html.p([attribute.style("color", "red")], [element.text(err.message)])
    _ -> element.none()
  }
}

fn view_items(items: RemoteData(List(Todo), RpcFailure)) -> Element(Msg) {
  case items {
    NotAsked | Loading ->
      html.p([attribute.style("opacity", "0.5")], [element.text("Loading...")])
    Failure(err) ->
      html.p([attribute.style("color", "red")], [element.text(err.message)])
    Success(todos) -> view_list(todos)
  }
}

fn view_list(items: List(Todo)) -> Element(Msg) {
  html.ul(
    [attribute.styles([#("list-style", "none"), #("padding", "0")])],
    list.map(items, view_item),
  )
}

fn view_item(item: Todo) -> Element(Msg) {
  let text_styles = case item.completed {
    True -> [#("text-decoration", "line-through"), #("opacity", "0.5")]
    False -> []
  }
  html.li(
    [
      attribute.styles([
        #("display", "flex"),
        #("align-items", "center"),
        #("gap", "0.5em"),
        #("padding", "0.5em 0"),
      ]),
    ],
    [
      html.span(
        [
          event.on_click(ToggleClicked(item.id)),
          attribute.styles([
            #("cursor", "pointer"),
            #("flex", "1"),
            ..text_styles
          ]),
        ],
        [element.text(item.title)],
      ),
      html.button(
        [
          event.on_click(DeleteClicked(item.id)),
          attribute.styles([
            #("cursor", "pointer"),
            #("border", "none"),
            #("background", "none"),
            #("color", "red"),
          ]),
        ],
        [element.text("x")],
      ),
    ],
  )
}

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}
