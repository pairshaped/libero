import gleeunit
import handler
import handler_context
import shared/types.{ItemParams}

pub fn main() {
  gleeunit.main()
}

pub fn create_item_returns_item_test() {
  let handler_ctx = handler_context.new()
  let #(result, _) =
    handler.create_item(params: ItemParams(title: "Buy milk"), handler_ctx:)
  let assert Ok(item) = result
  let assert "Buy milk" = item.title
  let assert False = item.completed
}
