import gleam/erlang/process
import gleam/io
import gleam/option.{type Option, None, Some}
import libero/error.{type PanicInfo, PanicInfo}
import mist.{type WebsocketConnection, type WebsocketMessage}
import server/generated/libero/rpc_dispatch

pub type State {
  State
}

pub fn init(
  _ws_conn: WebsocketConnection,
) -> #(State, Option(process.Selector(Nil))) {
  #(State, None)
}

pub fn handle_message(
  state: State,
  message: WebsocketMessage(Nil),
  conn: WebsocketConnection,
) -> mist.Next(State, Nil) {
  case message {
    mist.Text(text) -> {
      // The example has no /// @inject functions, so libero's generated
      // dispatch uses `session: Nil`. Real apps pass a typed Session
      // value and the inject fns route session fields into each RPC.
      let #(response_text, maybe_panic) =
        rpc_dispatch.handle(session: Nil, text: text)
      log_panic(maybe_panic)
      let _ = mist.send_text_frame(conn, response_text)
      mist.continue(state)
    }
    mist.Binary(_) -> mist.continue(state)
    mist.Closed | mist.Shutdown -> mist.stop()
    mist.Custom(_) -> mist.continue(state)
  }
}

fn log_panic(info: Option(PanicInfo)) -> Nil {
  case info {
    Some(PanicInfo(trace_id: trace_id, fn_name: fn_name, reason: reason)) ->
      io.println_error(
        "libero panic trace_id="
        <> trace_id
        <> " fn="
        <> fn_name
        <> " reason="
        <> reason,
      )
    None -> Nil
  }
}
