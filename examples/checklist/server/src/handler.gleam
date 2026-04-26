import gleam/list
import handler_context.{type HandlerContext, HandlerContext}
import shared/types.{
  type Item, type ItemError, type ItemParams, Item, NotFound, TitleRequired,
}

pub fn get_items(
  state state: HandlerContext,
) -> #(Result(List(Item), ItemError), HandlerContext) {
  #(Ok(state.items), state)
}

pub fn create_item(
  params params: ItemParams,
  state state: HandlerContext,
) -> #(Result(Item, ItemError), HandlerContext) {
  case params.title {
    "" -> #(Error(TitleRequired), state)
    title -> {
      let item = Item(id: state.next_id, title:, completed: False)
      let new_state =
        HandlerContext(
          items: list.append(state.items, [item]),
          next_id: state.next_id + 1,
        )
      #(Ok(item), new_state)
    }
  }
}

pub fn toggle_item(
  id id: Int,
  state state: HandlerContext,
) -> #(Result(Item, ItemError), HandlerContext) {
  case list.find(state.items, fn(t) { t.id == id }) {
    Error(_) -> #(Error(NotFound), state)
    Ok(item) -> {
      let toggled = Item(..item, completed: !item.completed)
      let new_state =
        HandlerContext(
          ..state,
          items: list.map(state.items, fn(t) {
            case t.id == id {
              True -> toggled
              False -> t
            }
          }),
        )
      #(Ok(toggled), new_state)
    }
  }
}

pub fn delete_item(
  id id: Int,
  state state: HandlerContext,
) -> #(Result(Int, ItemError), HandlerContext) {
  case list.find(state.items, fn(t) { t.id == id }) {
    Error(_) -> #(Error(NotFound), state)
    Ok(_) -> {
      let new_state =
        HandlerContext(
          ..state,
          items: list.filter(state.items, fn(t) { t.id != id }),
        )
      #(Ok(id), new_state)
    }
  }
}
