import ets_store

pub type HandlerContext {
  HandlerContext
}

pub fn new() -> HandlerContext {
  ets_store.init()
  HandlerContext
}
