import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/string
import mist.{type Connection, type ResponseData}
import simplifile

const static_dir = "priv/static"

pub fn serve_index(_req: Request(Connection)) -> Response(ResponseData) {
  let assert Ok(html) = simplifile.read(static_dir <> "/index.html")
  response.new(200)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(html)))
}

pub fn serve_static(
  _req: Request(Connection),
  segments: List(String),
) -> Response(ResponseData) {
  let rel_path = string.join(segments, "/")
  let path = static_dir <> "/" <> rel_path
  case simplifile.read_bits(path) {
    Ok(bytes) ->
      response.new(200)
      |> response.set_header("content-type", content_type_for(rel_path))
      |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(bytes)))
    Error(_) ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("not found")))
  }
}

fn content_type_for(path: String) -> String {
  case string.ends_with(path, ".mjs") || string.ends_with(path, ".js") {
    True -> "application/javascript; charset=utf-8"
    False ->
      case string.ends_with(path, ".html") {
        True -> "text/html; charset=utf-8"
        False -> "application/octet-stream"
      }
  }
}
