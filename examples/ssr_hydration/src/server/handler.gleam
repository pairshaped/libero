import ets_store
import server/app_error.{type AppError}
import server/shared_state.{type SharedState}
import shared/messages.{
  type MsgFromClient, type MsgFromServer, CounterUpdated, Decrement, GetCounter,
  Increment,
}

pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> Result(#(MsgFromServer, SharedState), AppError) {
  case msg {
    Increment -> Ok(#(CounterUpdated(Ok(ets_store.increment())), state))
    Decrement -> Ok(#(CounterUpdated(Ok(ets_store.decrement())), state))
    GetCounter -> Ok(#(CounterUpdated(Ok(ets_store.get())), state))
  }
}
