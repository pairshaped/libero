import gleam/list
import handler_context.{type HandlerContext, HandlerContext}
import shared/types.{type Todo, NotFound, TitleRequired, Todo}

// Each pub function below is an RPC endpoint. Libero's scanner detects these
// by checking four criteria: (1) public, (2) last param is HandlerContext,
// (3) returns #(Result(value, error), HandlerContext), and (4) all types in
// the signature come from shared/ or are builtins.
//
// These functions can live in any module under src/, not just this one.
// Larger apps typically organize handlers into domain modules (e.g.
// users.gleam, posts.gleam). The scanner walks all server source files
// and collects every function that matches the criteria.
//
// The codegen reads these signatures and generates:
//   - A ClientMsg variant per function (e.g. GetTodos, CreateTodo(params: TodoParams))
//   - A dispatch module that routes each variant to its handler function
//   - Typed client stubs that send the message and decode the response
//
// The return type Result(a, e) maps directly to RemoteData on the client:
//   Ok(value)  -> Success(value)
//   Error(err) -> Failure(err)   (typed domain error, not a string)

// get_todos -> generates ClientMsg variant: GetTodos (no params besides state)
// Client stub: rpc.get_todos(on_response: GotTodos)
// Wire: encodes GetTodos, server returns Result(List(Todo), TodoError)
pub fn get_todos(
  state state: HandlerContext,
) -> #(Result(List(Todo), types.TodoError), HandlerContext) {
  #(Ok(state.todos), state)
}

// create_todo -> generates ClientMsg variant: CreateTodo(params: TodoParams)
// Client stub: rpc.create_todo(params: TodoParams(..), on_response: GotCreated)
// The scanner converts snake_case fn name to PascalCase variant name.
// Non-state params become fields on the variant.
pub fn create_todo(
  params params: types.TodoParams,
  state state: HandlerContext,
) -> #(Result(Todo, types.TodoError), HandlerContext) {
  case params.title {
    "" -> #(Error(TitleRequired), state)
    title -> {
      let item = Todo(id: state.next_id, title:, completed: False)
      let state =
        HandlerContext(
          todos: list.append(state.todos, [item]),
          next_id: state.next_id + 1,
        )
      #(Ok(item), state)
    }
  }
}

// toggle_todo -> generates ClientMsg variant: ToggleTodo(id: Int)
// Client stub: rpc.toggle_todo(id: 42, on_response: GotToggled)
// Dispatch routes ToggleTodo(id:) to this function, forwarding the id param.
pub fn toggle_todo(
  id id: Int,
  state state: HandlerContext,
) -> #(Result(Todo, types.TodoError), HandlerContext) {
  case list.find(state.todos, fn(t) { t.id == id }) {
    Error(Nil) -> #(Error(NotFound), state)
    Ok(item) -> {
      let toggled = Todo(..item, completed: !item.completed)
      let todos =
        list.map(state.todos, fn(t) {
          case t.id == id {
            True -> toggled
            False -> t
          }
        })
      #(Ok(toggled), HandlerContext(..state, todos:))
    }
  }
}

// delete_todo -> generates ClientMsg variant: DeleteTodo(id: Int)
// Client stub: rpc.delete_todo(id: 42, on_response: GotDeleted)
// Returns Result(Int, TodoError) so the client gets the deleted id on success.
pub fn delete_todo(
  id id: Int,
  state state: HandlerContext,
) -> #(Result(Int, types.TodoError), HandlerContext) {
  case list.any(state.todos, fn(t) { t.id == id }) {
    False -> #(Error(NotFound), state)
    True -> {
      let todos = list.filter(state.todos, fn(t) { t.id != id })
      #(Ok(id), HandlerContext(..state, todos:))
    }
  }
}
