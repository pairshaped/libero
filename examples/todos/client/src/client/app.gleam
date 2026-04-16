import client/generated/libero/todos as rpc
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/string
import libero/error.{type RpcError, AppError, InternalError}
import libero/wire
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/todos.{
  type ToClient, type Todo, AllLoaded, Created, Deleted, TodoFailed,
  Create, Delete, LoadAll, Toggle, TodoParams, Toggled,
}

// ---- Model ----

pub type Model {
  Model(items: List(Todo), input: String, error: String)
}

// ---- Msg ----

pub type Msg {
  InputChanged(String)
  Submit
  ToggleClicked(Int)
  DeleteClicked(Int)
  GotResponse(Result(ToClient, RpcError(todos.TodoError)))
}

// ---- Init ----

pub fn init(_flags: Nil) -> #(Model, Effect(Msg)) {
  #(Model(items: [], input: "", error: ""), send(LoadAll))
}

// ---- Update ----

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    InputChanged(value) -> #(Model(..model, input: value), effect.none())

    Submit -> {
      case model.input {
        "" -> #(model, effect.none())
        title -> #(
          Model(..model, input: ""),
          send(Create(TodoParams(title:))),
        )
      }
    }

    ToggleClicked(id) -> #(model, send(Toggle(id:)))

    DeleteClicked(id) -> #(model, send(Delete(id:)))

    GotResponse(Ok(response)) -> {
      case response {
        AllLoaded(loaded) ->
          #(Model(..model, items: loaded, error: ""), effect.none())
        Created(item) ->
          #(
            Model(..model, items: list.append(model.items, [item]), error: ""),
            effect.none(),
          )
        Toggled(item) -> {
          let new_items =
            list.map(model.items, fn(t) {
              case t.id == item.id {
                True -> item
                False -> t
              }
            })
          #(Model(..model, items: new_items, error: ""), effect.none())
        }
        Deleted(id) -> {
          let new_items = list.filter(model.items, fn(t) { t.id != id })
          #(Model(..model, items: new_items, error: ""), effect.none())
        }
        TodoFailed(err) -> {
          let message = case err {
            todos.NotFound -> "Not found"
            todos.TitleRequired -> "Title is required"
          }
          #(Model(..model, error: message), effect.none())
        }
      }
    }

    GotResponse(Error(AppError(err))) -> {
      let message = case err {
        todos.NotFound -> "Not found"
        todos.TitleRequired -> "Title is required"
      }
      #(Model(..model, error: message), effect.none())
    }

    GotResponse(Error(InternalError(_, message))) ->
      #(Model(..model, error: message), effect.none())

    GotResponse(Error(_)) ->
      #(Model(..model, error: "Something went wrong"), effect.none())
  }
}

fn send(msg: todos.ToServer) -> Effect(Msg) {
  log("send: " <> string.inspect(msg))
  rpc.send(msg:, on_response: fn(raw: Dynamic) {
    let response = wire.coerce(raw)
    log("recv: " <> string.inspect(response))
    GotResponse(response)
  })
}

// ---- View ----

pub fn view(model: Model) -> Element(Msg) {
  html.div(
    [attribute.styles([#("max-width", "400px"), #("margin", "2em auto"), #("font-family", "system-ui, sans-serif")])],
    [
      html.h1([], [element.text("Todos")]),
      view_input(model),
      case model.error {
        "" -> element.none()
        msg -> html.p([attribute.style("color", "red")], [element.text(msg)])
      },
      view_list(model.items),
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
    [attribute.styles([#("display", "flex"), #("align-items", "center"), #("gap", "0.5em"), #("padding", "0.5em 0")])],
    [
      html.span(
        [
          event.on_click(ToggleClicked(item.id)),
          attribute.styles([#("cursor", "pointer"), #("flex", "1"), ..text_styles]),
        ],
        [element.text(item.title)],
      ),
      html.button(
        [
          event.on_click(DeleteClicked(item.id)),
          attribute.styles([#("cursor", "pointer"), #("border", "none"), #("background", "none"), #("color", "red")]),
        ],
        [element.text("x")],
      ),
    ],
  )
}

@external(javascript, "../client_ffi.mjs", "log")
fn log(msg: String) -> Nil

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}
