/// CLI client for the todos example.
/// Sends MsgFromClient messages to the server via HTTP POST.
/// No libero dependency — just native ETF encoding over HTTP.
///
/// Usage:
///   gleam run -- list
///   gleam run -- create "Buy milk"
///   gleam run -- toggle 1
///   gleam run -- delete 1

import gleam/io
import gleam/string
import shared/todos.{
  type MsgFromServer, AllLoaded, Create, Created, Delete, Deleted, LoadAll,
  TodoFailed, TodoParams, Toggle, Toggled,
}

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
  io.println("Todos CLI — libero example using HTTP POST + native ETF")
  io.println("")
  io.println("Usage:")
  io.println("  gleam run -- list              List all todos")
  io.println("  gleam run -- create <title>    Create a new todo")
  io.println("  gleam run -- toggle <id>       Toggle completed status")
  io.println("  gleam run -- delete <id>       Delete a todo")
  io.println("  gleam run -- help              Show this help")
}

fn do_list() {
  case rpc(url, module, LoadAll) {
    Ok(AllLoaded(items)) ->
      case items {
        [] -> io.println("No todos.")
        _ ->
          list_each(items, fn(item) {
            let check = case item.completed {
              True -> "[x]"
              False -> "[ ]"
            }
            io.println(
              check
              <> " #"
              <> int_to_string(item.id)
              <> " "
              <> item.title,
            )
          })
      }
    Ok(other) -> io.println_error("Unexpected: " <> string.inspect(other))
    Error(reason) -> io.println_error("Error: " <> reason)
  }
}

fn do_create(title: String) {
  case rpc(url, module, Create(TodoParams(title:))) {
    Ok(Created(item)) ->
      io.println(
        "Created #" <> int_to_string(item.id) <> " " <> item.title,
      )
    Ok(TodoFailed(err)) ->
      io.println_error("Failed: " <> string.inspect(err))
    Ok(other) -> io.println_error("Unexpected: " <> string.inspect(other))
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
    Ok(id) ->
      case rpc(url, module, msg_fn(id)) {
        Ok(Toggled(item)) -> {
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
        Ok(Deleted(id:)) ->
          io.println("Deleted #" <> int_to_string(id))
        Ok(TodoFailed(err)) ->
          io.println_error("Failed: " <> string.inspect(err))
        Ok(other) ->
          io.println_error("Unexpected: " <> string.inspect(other))
        Error(reason) ->
          io.println_error(action <> " error: " <> reason)
      }
  }
}

// -- Erlang FFI --

@external(erlang, "cli_ffi", "rpc")
fn rpc(
  url: String,
  module: String,
  msg: a,
) -> Result(MsgFromServer, String)

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
