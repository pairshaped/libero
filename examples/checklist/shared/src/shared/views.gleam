import gleam/list
import libero/remote_data.{type RpcData, Failure, Loading, NotAsked, Success}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/router.{type Route, Home}
import shared/types.{type Item, type ItemError, NotFound, TitleRequired}

pub type Model {
  Model(route: Route, items: RpcData(List(Item), ItemError), input: String)
}

pub type Msg {
  NavigateTo(Route)
  NoOp
  UserTyped(value: String)
  UserSubmittedTitle
  UserToggled(id: Int)
  UserDeleted(id: Int)
}

pub fn title(model: Model) -> String {
  case model.route {
    Home -> "Checklist"
  }
}

pub fn view(model: Model) -> Element(Msg) {
  case model.route {
    Home -> home_view(model)
  }
}

fn home_view(model: Model) -> Element(Msg) {
  html.main(
    [
      attribute.styles([
        #("max-width", "32rem"),
        #("margin", "2rem auto"),
        #("font-family", "system-ui, sans-serif"),
      ]),
    ],
    [
      html.h1([], [html.text("Checklist")]),
      view_form(model.input),
      view_items(model.items),
    ],
  )
}

fn view_form(input: String) -> Element(Msg) {
  html.form(
    [
      event.on_submit(fn(_) { UserSubmittedTitle }),
      attribute.styles([#("display", "flex"), #("gap", "0.5rem")]),
    ],
    [
      html.input([
        attribute.type_("text"),
        attribute.value(input),
        attribute.placeholder("What needs doing?"),
        event.on_input(UserTyped),
        attribute.style("flex", "1"),
      ]),
      html.button([attribute.type_("submit")], [html.text("Add")]),
    ],
  )
}

fn view_items(items: RpcData(List(Item), ItemError)) -> Element(Msg) {
  case items {
    NotAsked -> element.none()
    Loading -> html.p([], [html.text("Loading…")])
    Failure(outcome) ->
      html.p([attribute.style("color", "crimson")], [
        html.text(remote_data.format_failure(
          outcome:,
          format_domain: format_error,
        )),
      ])
    Success(items) ->
      html.ul([attribute.style("padding", "0")], list.map(items, view_item))
  }
}

fn view_item(item: Item) -> Element(Msg) {
  html.li(
    [
      attribute.styles([
        #("display", "flex"),
        #("gap", "0.5rem"),
        #("align-items", "center"),
        #("padding", "0.5rem 0"),
        #("list-style", "none"),
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
          ]),
        ],
        [html.text(item.title)],
      ),
      html.button([event.on_click(UserDeleted(item.id))], [html.text("Delete")]),
    ],
  )
}

fn format_error(err: ItemError) -> String {
  case err {
    NotFound -> "That item is gone."
    TitleRequired -> "Title is required."
  }
}
