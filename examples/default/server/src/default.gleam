//// Server entry point.

import generated/dispatch
import generated/websocket as ws
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/option.{None, Some}
import gleam/string
import handler_context
import libero/push
import libero/ssr
import libero/ws_logger
import mist.{type Connection}
import page
import shared/router
import simplifile

pub fn main() {
  let _ = push.init()
  let _ = dispatch.ensure_atoms()
  let state = handler_context.new()
  let logger = ws_logger.default_logger()

  let assert Ok(_) =
    fn(req: Request(Connection)) {
      case req.method, request.path_segments(req) {
        _, ["ws"] -> ws.upgrade(request: req, state:, topics: [], logger:)
        http.Post, ["rpc"] -> handle_rpc(req, state, logger)
        _, ["web", ..path] ->
          serve_file(
            "../clients/web/build/dev/javascript/" <> string.join(path, "/"),
          )
        _, _ ->
          ssr.handle_request(
            req:,
            parse: router.parse_route,
            load: page.load_page,
            render: page.render_page,
            state:,
          )
      }
    }
    |> mist.new
    |> mist.port(8080)
    |> mist.start

  process.sleep_forever()
}

fn handle_rpc(
  req: Request(Connection),
  state: handler_context.HandlerContext,
  logger: ws_logger.Logger,
) -> response.Response(mist.ResponseData) {
  case mist.read_body(req, 1_000_000) {
    Ok(req) -> {
      let #(response_bytes, maybe_panic, _new_state) =
        dispatch.handle(state:, data: req.body)
      case maybe_panic {
        Some(info) ->
          logger.error(
            "RPC panic: "
            <> info.fn_name
            <> " (trace "
            <> info.trace_id
            <> "): "
            <> info.reason,
          )
        None -> Nil
      }
      response.new(200)
      |> response.set_body(
        mist.Bytes(bytes_tree.from_bit_array(response_bytes)),
      )
    }
    Error(_) ->
      response.new(400)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Bad request")))
  }
}

fn serve_file(path: String) -> response.Response(mist.ResponseData) {
  case simplifile.read_bits(path) {
    Ok(bytes) ->
      response.new(200)
      |> response.set_header("content-type", content_type_for(path))
      |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(bytes)))
    Error(_) ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Not found")))
  }
}

fn content_type_for(path: String) -> String {
  case string.ends_with(path, ".mjs") || string.ends_with(path, ".js") {
    True -> "application/javascript"
    False ->
      case string.ends_with(path, ".css") {
        True -> "text/css"
        False -> "application/octet-stream"
      }
  }
}
