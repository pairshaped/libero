import gleam/list
import handler_context.{type HandlerContext, HandlerContext}
import shared/types.{
  type Item, type ItemError, type ItemParams, Item, NotFound, TitleRequired,
}

// `get_items` reads from the context without producing a new one, so it
// uses the bare-Result return shape. The mutating handlers below emit a
// new HandlerContext and use the `#(Result(_, _), HandlerContext)` form.
pub fn get_items(
  handler_ctx handler_ctx: HandlerContext,
) -> Result(List(Item), ItemError) {
  Ok(handler_ctx.items)
}

pub fn create_item(
  params params: ItemParams,
  handler_ctx handler_ctx: HandlerContext,
) -> #(Result(Item, ItemError), HandlerContext) {
  case params.title {
    "" -> #(Error(TitleRequired), handler_ctx)
    title -> {
      let item = Item(id: handler_ctx.next_id, title:, completed: False)
      let new_state =
        HandlerContext(
          items: list.append(handler_ctx.items, [item]),
          next_id: handler_ctx.next_id + 1,
        )
      #(Ok(item), new_state)
    }
  }
}

pub fn toggle_item(
  id id: Int,
  handler_ctx handler_ctx: HandlerContext,
) -> #(Result(Item, ItemError), HandlerContext) {
  case list.find(handler_ctx.items, fn(t) { t.id == id }) {
    Error(_) -> #(Error(NotFound), handler_ctx)
    Ok(item) -> {
      let toggled = Item(..item, completed: !item.completed)
      let new_state =
        HandlerContext(
          ..handler_ctx,
          items: list.map(handler_ctx.items, fn(t) {
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
  handler_ctx handler_ctx: HandlerContext,
) -> #(Result(Int, ItemError), HandlerContext) {
  case list.find(handler_ctx.items, fn(t) { t.id == id }) {
    Error(_) -> #(Error(NotFound), handler_ctx)
    Ok(_) -> {
      let new_state =
        HandlerContext(
          ..handler_ctx,
          items: list.filter(handler_ctx.items, fn(t) { t.id != id }),
        )
      #(Ok(id), new_state)
    }
  }
}
