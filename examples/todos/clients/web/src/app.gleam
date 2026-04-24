import generated/messages as rpc
import gleam/list
import libero/remote_data.{type RemoteData, Failure, Loading, NotAsked, Success}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/types.{type Todo, type TodoError, TodoParams}

// --- Model ---

pub type Model {
  Model(todos: RemoteData(List(Todo), TodoError), input: String)
}

fn init(_flags) -> #(Model, Effect(Msg)) {
  // rpc.get_todos sends GetTodos over the WebSocket to the server handler.
  // on_response wraps the decoded result in our GotTodos msg. The response
  // arrives as RemoteData(List(Todo), TodoError) -- either Success(todos)
  // or Failure(domain_error). We set todos to Loading while we wait.
  #(Model(todos: Loading, input: ""), rpc.get_todos(on_response: GotTodos))
}

// --- Messages ---

pub type Msg {
  UserTyped(value: String)
  UserSubmitted
  UserToggled(id: Int)
  UserDeleted(id: Int)
  // Each Got* variant carries a RemoteData with typed domain errors.
  // The generated stubs decode the server's Result(a, e) into
  // RemoteData(a, e) automatically: Ok -> Success, Error -> Failure.
  GotTodos(RemoteData(List(Todo), TodoError))
  GotCreated(RemoteData(Todo, TodoError))
  GotToggled(RemoteData(Todo, TodoError))
  GotDeleted(RemoteData(Int, TodoError))
}

// --- Update ---

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UserTyped(value:) -> #(Model(..model, input: value), effect.none())
    UserSubmitted ->
      case model.input {
        "" -> #(model, effect.none())
        title -> #(
          Model(..model, input: ""),
          // Send CreateTodo with the form input. The server handler validates
          // the title and returns either Ok(Todo) or Error(TitleRequired).
          rpc.create_todo(params: TodoParams(title:), on_response: GotCreated),
        )
      }
    // Each of these sends a typed RPC call over the WebSocket. The generated
    // stub serializes the params, assigns a request ID for matching, and
    // decodes the response into RemoteData when it arrives.
    UserToggled(id:) -> #(model, rpc.toggle_todo(id:, on_response: GotToggled))
    UserDeleted(id:) -> #(model, rpc.delete_todo(id:, on_response: GotDeleted))
    // RemoteData responses: pattern match on Success/Failure to update
    // the model. Success carries the decoded value, Failure carries the
    // typed domain error (e.g. NotFound, TitleRequired).
    GotTodos(rd) -> #(Model(..model, todos: rd), effect.none())
    GotCreated(Success(item)) -> #(
      Model(
        ..model,
        todos: remote_data.map(data: model.todos, transform: fn(todos) {
          list.append(todos, [item])
        }),
      ),
      effect.none(),
    )
    GotToggled(Success(toggled)) -> #(
      Model(
        ..model,
        todos: remote_data.map(data: model.todos, transform: fn(todos) {
          list.map(todos, fn(t) {
            case t.id == toggled.id {
              True -> toggled
              False -> t
            }
          })
        }),
      ),
      effect.none(),
    )
    GotDeleted(Success(id)) -> #(
      Model(
        ..model,
        todos: remote_data.map(data: model.todos, transform: fn(todos) {
          list.filter(todos, fn(t) { t.id != id })
        }),
      ),
      effect.none(),
    )
    _ -> #(model, effect.none())
  }
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
      // RemoteData drives the view: show loading spinner, error message
      // with typed domain errors, or the todo list on success.
      case model.todos {
        NotAsked -> html.text("")
        Loading -> html.p([], [html.text("Loading...")])
        Failure(err) ->
          html.p([attribute.style("color", "red")], [
            html.text(format_error(err)),
          ])
        Success(todos) -> view_todo_list(todos)
      },
    ],
  )
}

fn format_error(err: TodoError) -> String {
  case err {
    types.NotFound -> "Not found"
    types.TitleRequired -> "Title is required"
  }
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
