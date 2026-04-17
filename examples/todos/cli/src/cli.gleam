/// CLI client for the todos example.
/// Sends MsgFromClient messages to the server via HTTP POST.
/// No libero dependency - just native ETF encoding over HTTP.
///
/// Usage:
///   gleam run -- list
///   gleam run -- create "Buy milk"
///   gleam run -- toggle 1
///   gleam run -- delete 1
import gleam/io
import shared/todos.{type Todo, Create, Delete, LoadAll, TodoParams, Toggle}

const url = "http://localhost:8080/rpc"

const module = "shared/todos"

pub fn main() {
  start_inets()
  case get_args() {
    ["list"] -> do_list()
    ["create", title] -> do_create(title)
    ["toggle", id_str] -> do_with_id("toggle", id_str, fn(id) { Toggle(id:) })
    ["delete", id_str] -> do_with_id("delete", id_str, fn(id) { Delete(id:) })
    ["help"] | ["--help"] | ["-h"] -> usage()
    _ -> {
      usage()
      halt(1)
    }
  }
}

fn usage() {
  io.println("Todos CLI - libero example using HTTP POST + native ETF")
  io.println("")
  io.println("Usage:")
  io.println("  gleam run -- list              List all todos")
  io.println("  gleam run -- create <title>    Create a new todo")
  io.println("  gleam run -- toggle <id>       Toggle completed status")
  io.println("  gleam run -- delete <id>       Delete a todo")
  io.println("  gleam run -- help              Show this help")
}

fn do_list() {
  let result: Result(List(Todo), String) = rpc(url, module, LoadAll)
  case result {
    Ok([]) -> io.println("No todos.")
    Ok(items) ->
      list_each(items, fn(item) {
        let check = case item.completed {
          True -> "[x]"
          False -> "[ ]"
        }
        io.println(check <> " #" <> int_to_string(item.id) <> " " <> item.title)
      })
    Error(reason) -> io.println_error("Error: " <> reason)
  }
}

fn do_create(title: String) {
  let result: Result(Todo, String) =
    rpc(url, module, Create(params: TodoParams(title:)))
  case result {
    Ok(item) ->
      io.println("Created #" <> int_to_string(item.id) <> " " <> item.title)
    Error(reason) -> io.println_error("Error: " <> reason)
  }
}

fn do_with_id(
  action: String,
  id_str: String,
  msg_fn: fn(Int) -> todos.MsgFromClient,
) {
  case parse_int(id_str) {
    Error(Nil) -> io.println_error("Invalid id: " <> id_str)
    Ok(id) -> {
      case msg_fn(id) {
        Toggle(id: tid) -> {
          let result: Result(Todo, String) = rpc(url, module, Toggle(id: tid))
          case result {
            Ok(item) -> {
              let status = case item.completed {
                True -> "completed"
                False -> "active"
              }
              io.println(
                "Toggled #"
                <> int_to_string(item.id)
                <> " "
                <> item.title
                <> " ("
                <> status
                <> ")",
              )
            }
            Error(reason) -> io.println_error(action <> " error: " <> reason)
          }
        }
        Delete(id: did) -> {
          let result: Result(Int, String) = rpc(url, module, Delete(id: did))
          case result {
            Ok(deleted_id) ->
              io.println("Deleted #" <> int_to_string(deleted_id))
            Error(reason) -> io.println_error(action <> " error: " <> reason)
          }
        }
        _ -> io.println_error("Unsupported action: " <> action)
      }
    }
  }
}

// -- Erlang FFI --

@external(erlang, "cli_ffi", "rpc")
fn rpc(url: String, module: String, msg: a) -> Result(b, String)

@external(erlang, "cli_ffi", "start_inets")
fn start_inets() -> Nil

@external(erlang, "cli_ffi", "int_to_string")
fn int_to_string(n: Int) -> String

@external(erlang, "cli_ffi", "list_each")
fn list_each(items: List(a), f: fn(a) -> Nil) -> Nil

@external(erlang, "cli_ffi", "parse_int")
fn parse_int(s: String) -> Result(Int, Nil)

@external(erlang, "cli_ffi", "get_args")
fn get_args() -> List(String)

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
