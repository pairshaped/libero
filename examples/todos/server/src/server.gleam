import gleam/erlang/process
import mist
import server/shared_state
import server/websocket as ws

pub fn main() {
  let shared = shared_state.new()

  let assert Ok(_) =
    fn(req) {
      mist.websocket(
        request: req,
        handler: ws.handler,
        on_init: ws.on_init(shared),
        on_close: fn(_state) { Nil },
      )
    }
    |> mist.new
    |> mist.port(8080)
    |> mist.start

  process.sleep_forever()
}
