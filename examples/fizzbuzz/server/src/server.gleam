//// FizzBuzz over libero RPC. Server entry point.
////
//// Runs a Mist HTTP + WebSocket server on Mist's default port (4000):
////
////   GET /             serves the Lustre app's index.html
////   GET /static/*     serves the compiled Lustre bundle
////   WS  /ws/rpc       upgrades to libero's RPC dispatch

import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import mist.{type Connection, type ResponseData}
import server/web
import server/websocket

pub fn main() -> Nil {
  let assert Ok(_) =
    handler
    |> mist.new
    |> mist.start

  process.sleep_forever()
}

fn handler(req: Request(Connection)) -> Response(ResponseData) {
  case request.path_segments(req) {
    [] -> web.serve_index(req)
    ["static", ..rest] -> web.serve_static(req, rest)
    ["ws", "rpc"] ->
      mist.websocket(
        request: req,
        on_init: fn(ws_conn) { websocket.init(ws_conn) },
        on_close: fn(_state) { Nil },
        handler: websocket.handle_message,
      )
    _ -> not_found()
  }
}

fn not_found() -> Response(ResponseData) {
  response.new(404)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("not found")))
}
