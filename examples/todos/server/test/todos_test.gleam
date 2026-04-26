import gleam/list
import gleeunit
import handler
import handler_context
import shared/types.{Todo, TodoParams}

pub fn main() {
  gleeunit.main()
}

fn fresh_state() -> handler_context.HandlerContext {
  handler_context.new()
}

pub fn create_with_empty_title_returns_error_test() {
  let state = fresh_state()
  let assert #(Error(types.TitleRequired), _) =
    handler.create_todo(params: TodoParams(title: ""), state:)
}

pub fn create_returns_todo_with_id_test() {
  let state = fresh_state()
  let assert #(Ok(Todo(id: _, title: "Buy milk", completed: False)), _) =
    handler.create_todo(params: TodoParams(title: "Buy milk"), state:)
}

pub fn get_todos_returns_created_todos_test() {
  let state = fresh_state()
  let assert #(Ok(_), state) =
    handler.create_todo(params: TodoParams(title: "First"), state:)
  let assert #(Ok(_), state) =
    handler.create_todo(params: TodoParams(title: "Second"), state:)
  let assert #(Ok(todos), _) = handler.get_todos(state:)
  let assert 2 = list.length(todos)
}

pub fn toggle_flips_completed_test() {
  let state = fresh_state()
  let assert #(Ok(item), state) =
    handler.create_todo(params: TodoParams(title: "Toggle me"), state:)
  let assert False = item.completed
  let assert #(Ok(toggled), _) = handler.toggle_todo(id: item.id, state:)
  let assert True = toggled.completed
}

pub fn toggle_nonexistent_returns_not_found_test() {
  let state = fresh_state()
  let assert #(Error(types.NotFound), _) = handler.toggle_todo(id: 9999, state:)
}

pub fn delete_removes_todo_test() {
  let state = fresh_state()
  let assert #(Ok(item), state) =
    handler.create_todo(params: TodoParams(title: "Delete me"), state:)
  let assert #(Ok(_), state) = handler.delete_todo(id: item.id, state:)
  let assert #(Ok(todos), _) = handler.get_todos(state:)
  let assert 0 = list.length(todos)
}

pub fn delete_nonexistent_returns_not_found_test() {
  let state = fresh_state()
  let assert #(Error(types.NotFound), _) = handler.delete_todo(id: 9999, state:)
}
