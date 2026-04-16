import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option.{None}
import gleam/string
import mist
import server/shared_state
import server/store
import server/websocket as ws
import server/generated/libero/dispatch

pub fn main() {
  store.init()
  let shared = shared_state.new()

  let assert Ok(_) =
    fn(req: request.Request(mist.Connection)) {
      case req.method, request.path_segments(req) {
        _, ["ws"] ->
          mist.websocket(
            request: req,
            handler: ws.handler,
            on_init: ws.on_init(shared),
            on_close: fn(_state) { Nil },
          )
        http.Post, ["rpc"] -> handle_rpc(req, shared)
        _, ["js", ..path] ->
          serve_file(
            "../client/build/dev/javascript/" <> string.join(path, "/"),
            "application/javascript",
          )
        _, _ -> serve_file("priv/static/index.html", "text/html")
      }
    }
    |> mist.new
    |> mist.port(8080)
    |> mist.start

  process.sleep_forever()
}

fn handle_rpc(
  req: request.Request(mist.Connection),
  shared: shared_state.SharedState,
) -> response.Response(mist.ResponseData) {
  case mist.read_body(req, 1_000_000) {
    Ok(req) -> {
      let #(response_bytes, _maybe_panic, _new_state) =
        dispatch.handle(state: shared, data: req.body)
      response.new(200)
      |> response.set_header("content-type", "application/octet-stream")
      |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(response_bytes)))
    }
    Error(_) ->
      response.new(400)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Bad request")))
  }
}

fn serve_file(
  path: String,
  content_type: String,
) -> response.Response(mist.ResponseData) {
  case mist.send_file(path, offset: 0, limit: None) {
    Ok(body) ->
      response.new(200)
      |> response.set_header("content-type", content_type)
      |> response.set_body(body)
    Error(_) ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Not found")))
  }
}
