/// ETS-backed todo store. Uses a named public table so any process
/// (WebSocket handler, HTTP handler) can read and write.
import gleam/list
import gleam/order
import server/app_error.{type AppError}
import server/generated/libero/todos as todos_push
import server/shared_state.{type SharedState}
import shared/todos.{
  type MsgFromClient, type MsgFromServer, type Todo, Create, Delete, LoadAll,
  NotFound, TitleRequired, Todo, TodoCreated, TodoDeleted, TodoToggled,
  TodosLoaded, Toggle,
}

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

/// Handle an RPC message from the client.
///
/// Domain errors (NotFound, TitleRequired) are wrapped in the response
/// variant's `Result` so the client surfaces them through `RemoteData`
/// just like successes. Reserve `AppError` for framework-level failures
/// (corrupt state, missing dependency).
pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> Result(#(MsgFromServer, SharedState), AppError) {
  case msg {
    Create(params:) -> {
      case params.title {
        "" -> Ok(#(TodoCreated(Error(TitleRequired)), state))
        title -> {
          let item = insert(title:)
          todos_push.send_to_clients(
            topic: "todos",
            msg: TodosLoaded(Ok(all())),
          )
          Ok(#(TodoCreated(Ok(item)), state))
        }
      }
    }
    Toggle(id:) -> {
      case toggle(id:) {
        Ok(toggled) -> {
          todos_push.send_to_clients(
            topic: "todos",
            msg: TodosLoaded(Ok(all())),
          )
          Ok(#(TodoToggled(Ok(toggled)), state))
        }
        Error(Nil) -> Ok(#(TodoToggled(Error(NotFound)), state))
      }
    }
    Delete(id:) -> {
      case delete(id:) {
        Ok(Nil) -> {
          todos_push.send_to_clients(
            topic: "todos",
            msg: TodosLoaded(Ok(all())),
          )
          Ok(#(TodoDeleted(Ok(id)), state))
        }
        Error(Nil) -> Ok(#(TodoDeleted(Error(NotFound)), state))
      }
    }
    LoadAll -> Ok(#(TodosLoaded(Ok(all())), state))
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
