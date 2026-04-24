import ets_store
import server/handler_context.{type HandlerContext}
import shared/messages.{
  type MsgFromClient, type MsgFromServer, CounterUpdated, Decrement, GetCounter,
  Increment,
}

pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: HandlerContext,
) -> #(MsgFromServer, HandlerContext) {
  case msg {
    Increment -> #(CounterUpdated(Ok(ets_store.increment())), state)
    Decrement -> #(CounterUpdated(Ok(ets_store.decrement())), state)
    GetCounter -> #(CounterUpdated(Ok(ets_store.get())), state)
  }
}
