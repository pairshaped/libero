import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/string
import libero/push
import libero/wire
import mist
import server/generated/libero/dispatch
import server/shared_state.{type SharedState}

pub type ConnState {
  ConnState(shared: SharedState)
}

pub type PushMsg {
  PushFrame(BitArray)
  Ignored
}

pub fn on_init(shared: SharedState) {
  fn(_conn: mist.WebsocketConnection) -> #(ConnState, Option(process.Selector(PushMsg))) {
    io.println("[ws] client connected")
    push.join(topic: "todos")
    let selector =
      process.new_selector()
      |> process.select_other(fn(msg: Dynamic) {
        case decode_push_msg(msg) {
          Ok(frame) -> PushFrame(frame)
          Error(Nil) -> Ignored
        }
      })
    #(ConnState(shared:), Some(selector))
  }
}

pub fn handler(
  state: ConnState,
  message: mist.WebsocketMessage(PushMsg),
  conn: mist.WebsocketConnection,
) -> mist.Next(ConnState, PushMsg) {
  case message {
    mist.Binary(data) -> {
      io.println("[ws] raw bytes: " <> string.inspect(data))
      case wire.decode_call(data) {
        Ok(#(module, msg)) ->
          io.println("[ws] recv " <> module <> ": " <> string.inspect(msg))
        Error(err) ->
          io.println("[ws] decode error: " <> string.inspect(err))
      }
      let #(response_bytes, maybe_panic, _new_shared) =
        dispatch.handle(state: state.shared, data:)
      case maybe_panic {
        Some(info) ->
          io.println("[ws] PANIC: " <> string.inspect(info))
        None -> Nil
      }
      let _ = mist.send_binary_frame(conn, response_bytes)
      mist.continue(state)
    }
    mist.Custom(PushFrame(frame)) -> {
      let _ = mist.send_binary_frame(conn, frame)
      mist.continue(state)
    }
    mist.Custom(Ignored) -> mist.continue(state)
    mist.Closed | mist.Shutdown -> {
      io.println("[ws] client disconnected")
      mist.stop()
    }
    mist.Text(_) -> mist.continue(state)
  }
}

@external(erlang, "server_websocket_ffi", "decode_push_msg")
fn decode_push_msg(msg: Dynamic) -> Result(BitArray, Nil)
