import shared/types.{type Item}

pub type HandlerContext {
  HandlerContext(items: List(Item), next_id: Int)
}

pub fn new() -> HandlerContext {
  HandlerContext(items: [], next_id: 1)
}
