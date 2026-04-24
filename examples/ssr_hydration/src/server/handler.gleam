import ets_store
import server/shared_state.{type SharedState}
import shared/messages.{
  type MsgFromClient, type MsgFromServer, CounterUpdated, Decrement, GetCounter,
  Increment,
}

pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> #(MsgFromServer, SharedState) {
  case msg {
    Increment -> #(CounterUpdated(Ok(ets_store.increment())), state)
    Decrement -> #(CounterUpdated(Ok(ets_store.decrement())), state)
    GetCounter -> #(CounterUpdated(Ok(ets_store.get())), state)
  }
}
