import generated/messages as rpc
import gleam/dynamic
import gleam/list
import libero/remote_data.{type RemoteData}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/messages.{
  type MsgFromServer, type Todo, type TodoError, Create, Delete, LoadAll,
  TodoCreated, TodoDeleted, TodoParams, TodoToggled, TodosLoaded, Toggle,
}

// --- Model ---

pub type Model {
  Model(todos: List(Todo), input: String, error: String)
}

fn init(_flags) -> #(Model, Effect(Msg)) {
  #(Model(todos: [], input: "", error: ""), load_all())
}

// --- Messages ---

pub type Msg {
  UserTyped(value: String)
  UserSubmitted
  UserToggled(id: Int)
  UserDeleted(id: Int)
  ServerResponded(dynamic.Dynamic)
}

// --- Update ---

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UserTyped(value:) -> #(
      Model(..model, input: value, error: ""),
      effect.none(),
    )
    UserSubmitted ->
      case model.input {
        "" -> #(Model(..model, error: "Title is required"), effect.none())
        title -> #(
          Model(..model, input: ""),
          rpc.send_to_server(
            msg: Create(params: TodoParams(title:)),
            on_response: ServerResponded,
          ),
        )
      }
    UserToggled(id:) -> #(
      model,
      rpc.send_to_server(msg: Toggle(id:), on_response: ServerResponded),
    )
    UserDeleted(id:) -> #(
      model,
      rpc.send_to_server(msg: Delete(id:), on_response: ServerResponded),
    )
    ServerResponded(raw) -> handle_server_response(model, raw)
  }
}

fn handle_server_response(
  model: Model,
  raw: dynamic.Dynamic,
) -> #(Model, Effect(Msg)) {
  // The wire sends Result(MsgFromServer, RpcError), not bare MsgFromServer.
  // remote_data.to_remote unwraps the Result and converts it to RemoteData,
  // which handles both RPC-level errors and domain errors cleanly.
  let rd: RemoteData(MsgFromServer, _) =
    remote_data.to_remote(raw:, format_domain: format_error)
  case rd {
    remote_data.Success(response) -> handle_success(model, response)
    remote_data.Failure(err) -> #(
      Model(..model, error: err.message),
      effect.none(),
    )
    _ -> #(model, effect.none())
  }
}

fn handle_success(
  model: Model,
  response: MsgFromServer,
) -> #(Model, Effect(Msg)) {
  case response {
    TodoCreated(Ok(item)) -> #(
      Model(..model, todos: list.append(model.todos, [item])),
      effect.none(),
    )
    TodoCreated(Error(_)) -> #(
      Model(..model, error: "Failed to create todo"),
      effect.none(),
    )
    TodoToggled(Ok(toggled)) -> #(
      Model(
        ..model,
        todos: list.map(model.todos, fn(t) {
          case t.id == toggled.id {
            True -> toggled
            False -> t
          }
        }),
      ),
      effect.none(),
    )
    TodoToggled(Error(_)) -> #(
      Model(..model, error: "Todo not found"),
      effect.none(),
    )
    TodoDeleted(Ok(id)) -> #(
      Model(..model, todos: list.filter(model.todos, fn(t) { t.id != id })),
      effect.none(),
    )
    TodoDeleted(Error(_)) -> #(
      Model(..model, error: "Todo not found"),
      effect.none(),
    )
    TodosLoaded(Ok(todos)) -> #(Model(..model, todos:), effect.none())
    TodosLoaded(Error(_)) -> #(
      Model(..model, error: "Failed to load todos"),
      effect.none(),
    )
  }
}

fn format_error(err: TodoError) -> String {
  case err {
    messages.NotFound -> "Not found"
    messages.TitleRequired -> "Title is required"
  }
}

fn load_all() -> Effect(Msg) {
  rpc.send_to_server(msg: LoadAll, on_response: ServerResponded)
}

// --- View ---

fn view(model: Model) -> Element(Msg) {
  html.div(
    [
      attribute.styles([
        #("max-width", "500px"),
        #("margin", "2rem auto"),
        #("font-family", "system-ui, sans-serif"),
      ]),
    ],
    [
      html.h1([], [html.text("Todos")]),
      view_form(model),
      case model.error {
        "" -> element.none()
        err -> html.p([attribute.style("color", "red")], [html.text(err)])
      },
      view_todo_list(model.todos),
    ],
  )
}

fn view_form(model: Model) -> Element(Msg) {
  html.form(
    [
      event.on_submit(fn(_) { UserSubmitted }),
      attribute.styles([
        #("display", "flex"),
        #("gap", "0.5rem"),
        #("margin-bottom", "1rem"),
      ]),
    ],
    [
      html.input([
        attribute.type_("text"),
        attribute.value(model.input),
        attribute.placeholder("What needs to be done?"),
        event.on_input(UserTyped),
        attribute.style("flex", "1"),
        attribute.style("padding", "0.5rem"),
      ]),
      html.button(
        [
          attribute.type_("submit"),
          attribute.style("padding", "0.5rem 1rem"),
        ],
        [html.text("Add")],
      ),
    ],
  )
}

fn view_todo_list(todos: List(Todo)) -> Element(Msg) {
  html.ul(
    [attribute.style("list-style", "none"), attribute.style("padding", "0")],
    list.map(todos, view_todo_item),
  )
}

fn view_todo_item(item: Todo) -> Element(Msg) {
  html.li(
    [
      attribute.styles([
        #("display", "flex"),
        #("align-items", "center"),
        #("gap", "0.5rem"),
        #("padding", "0.5rem 0"),
        #("border-bottom", "1px solid #eee"),
      ]),
    ],
    [
      html.input([
        attribute.type_("checkbox"),
        attribute.checked(item.completed),
        event.on_check(fn(_) { UserToggled(item.id) }),
      ]),
      html.span(
        [
          attribute.styles([
            #("flex", "1"),
            #("text-decoration", case item.completed {
              True -> "line-through"
              False -> "none"
            }),
            #("opacity", case item.completed {
              True -> "0.5"
              False -> "1"
            }),
          ]),
        ],
        [html.text(item.title)],
      ),
      html.button(
        [
          event.on_click(UserDeleted(item.id)),
          attribute.styles([
            #("color", "red"),
            #("border", "none"),
            #("background", "none"),
            #("cursor", "pointer"),
          ]),
        ],
        [html.text("x")],
      ),
    ],
  )
}

// --- Main ---

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}
