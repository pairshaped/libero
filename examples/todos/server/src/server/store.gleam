/// ETS-backed todo store. Uses a named public table so any process
/// (WebSocket handler, HTTP handler) can read and write.

import gleam/list
import gleam/order
import shared/todos.{type Todo, Todo}

/// Create the ETS table. Call once at server boot.
pub fn init() -> Nil {
  create_table()
}

/// Return all todos sorted by ID.
pub fn all() -> List(Todo) {
  all_rows()
  |> list.sort(fn(a, b) { int_compare(a.id, b.id) })
}

/// Insert a todo with an auto-incremented ID. Returns the new todo.
pub fn insert(title title: String) -> Todo {
  let id = next_id()
  let item = Todo(id:, title:, completed: False)
  put(id, item)
  item
}

/// Toggle a todo's completed flag. Returns the updated todo or Error(Nil).
pub fn toggle(id id: Int) -> Result(Todo, Nil) {
  case get(id) {
    Error(Nil) -> Error(Nil)
    Ok(item) -> {
      let toggled = Todo(..item, completed: !item.completed)
      put(id, toggled)
      Ok(toggled)
    }
  }
}

/// Delete a todo by ID. Returns Ok(Nil) if found, Error(Nil) if not.
pub fn delete(id id: Int) -> Result(Nil, Nil) {
  case get(id) {
    Error(Nil) -> Error(Nil)
    Ok(_) -> {
      delete_row(id)
      Ok(Nil)
    }
  }
}

// -- Erlang FFI --

@external(erlang, "server_store_ffi", "create_table")
fn create_table() -> Nil

@external(erlang, "server_store_ffi", "next_id")
fn next_id() -> Int

@external(erlang, "server_store_ffi", "put")
fn put(id: Int, item: Todo) -> Nil

@external(erlang, "server_store_ffi", "get")
fn get(id: Int) -> Result(Todo, Nil)

@external(erlang, "server_store_ffi", "all_rows")
fn all_rows() -> List(Todo)

@external(erlang, "server_store_ffi", "delete_row")
fn delete_row(id: Int) -> Nil

@external(erlang, "server_store_ffi", "int_compare")
fn int_compare(a: Int, b: Int) -> order.Order
