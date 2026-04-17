import gleam/list
import libero/remote_data.{
  type RemoteData, type RpcFailure, Failure, Loading, NotAsked, Success,
}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/todos.{type MsgFromServer, type Todo}

pub type Model {
  Model(
    items: RemoteData(List(Todo), RpcFailure),
    input: String,
    last_action: RemoteData(Nil, RpcFailure),
  )
}

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
      html.h1([], [element.text("Todos (hydrated)")]),
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
