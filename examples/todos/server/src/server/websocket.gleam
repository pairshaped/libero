import gleam/erlang/process
import gleam/option.{type Option, None}
import mist
import server/generated/libero/dispatch
import server/shared_state.{type SharedState}

pub type State {
  State(shared: SharedState)
}

pub fn on_init(shared: SharedState) {
  fn(_conn: mist.WebsocketConnection) -> #(State, Option(process.Selector(Nil))) {
    #(State(shared:), None)
  }
}

pub fn handler(
  state: State,
  message: mist.WebsocketMessage(Nil),
  conn: mist.WebsocketConnection,
) -> mist.Next(State, Nil) {
  case message {
    mist.Binary(data) -> {
      let #(response_bytes, _maybe_panic) =
        dispatch.handle(state: state.shared, data:)
      let _ = mist.send_binary_frame(conn, response_bytes)
      mist.continue(state)
    }
    mist.Closed | mist.Shutdown -> mist.stop()
    mist.Text(_) -> mist.continue(state)
    mist.Custom(_) -> mist.continue(state)
  }
}
