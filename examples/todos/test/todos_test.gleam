import gleam/list
import core/handler
import core/messages.{
  Create, Delete, LoadAll, Todo, TodoCreated, TodoDeleted, TodoToggled,
  TodoParams, TodosLoaded, Toggle,
}
import core/shared_state
import gleeunit

pub fn main() {
  gleeunit.main()
}

fn fresh_state() -> shared_state.SharedState {
  shared_state.new()
}

pub fn create_with_empty_title_returns_error_test() {
  let state = fresh_state()
  let assert Ok(#(TodoCreated(Error(messages.TitleRequired)), _)) =
    handler.update_from_client(
      msg: Create(params: TodoParams(title: "")),
      state:,
    )
}

pub fn create_returns_todo_with_id_test() {
  let state = fresh_state()
  let assert Ok(#(TodoCreated(Ok(Todo(id: _, title: "Buy milk", completed: False))), _)) =
    handler.update_from_client(
      msg: Create(params: TodoParams(title: "Buy milk")),
      state:,
    )
}

pub fn load_all_returns_created_todos_test() {
  let state = fresh_state()
  let assert Ok(#(TodoCreated(Ok(_)), state)) =
    handler.update_from_client(
      msg: Create(params: TodoParams(title: "First")),
      state:,
    )
  let assert Ok(#(TodoCreated(Ok(_)), state)) =
    handler.update_from_client(
      msg: Create(params: TodoParams(title: "Second")),
      state:,
    )
  let assert Ok(#(TodosLoaded(Ok(todos)), _)) =
    handler.update_from_client(msg: LoadAll, state:)
  let assert 2 = list.length(todos)
}

pub fn toggle_flips_completed_test() {
  let state = fresh_state()
  let assert Ok(#(TodoCreated(Ok(item)), state)) =
    handler.update_from_client(
      msg: Create(params: TodoParams(title: "Toggle me")),
      state:,
    )
  let assert False = item.completed
  let assert Ok(#(TodoToggled(Ok(toggled)), _)) =
    handler.update_from_client(msg: Toggle(id: item.id), state:)
  let assert True = toggled.completed
}

pub fn toggle_nonexistent_returns_not_found_test() {
  let state = fresh_state()
  let assert Ok(#(TodoToggled(Error(messages.NotFound)), _)) =
    handler.update_from_client(msg: Toggle(id: 9999), state:)
}

pub fn delete_removes_todo_test() {
  let state = fresh_state()
  let assert Ok(#(TodoCreated(Ok(item)), state)) =
    handler.update_from_client(
      msg: Create(params: TodoParams(title: "Delete me")),
      state:,
    )
  let assert Ok(#(TodoDeleted(Ok(_)), state)) =
    handler.update_from_client(msg: Delete(id: item.id), state:)
  let assert Ok(#(TodosLoaded(Ok(todos)), _)) =
    handler.update_from_client(msg: LoadAll, state:)
  let assert 0 = list.length(todos)
}

pub fn delete_nonexistent_returns_not_found_test() {
  let state = fresh_state()
  let assert Ok(#(TodoDeleted(Error(messages.NotFound)), _)) =
    handler.update_from_client(msg: Delete(id: 9999), state:)
}
