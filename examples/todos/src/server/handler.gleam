import ets_store
import server/handler_context.{type HandlerContext}
import shared/types.{type Todo, NotFound, TitleRequired, Todo}

// Each pub function below is an RPC endpoint. Libero's scanner detects these
// by checking four criteria: (1) public, (2) last param is HandlerContext,
// (3) returns #(Result(value, error), HandlerContext), and (4) all types in
// the signature come from shared/ or are builtins.
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
  #(Ok(ets_store.all()), state)
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
      let id = ets_store.next_id()
      let item = Todo(id:, title:, completed: False)
      ets_store.insert(id, item)
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
  case ets_store.lookup(id) {
    Error(Nil) -> #(Error(NotFound), state)
    Ok(item) -> {
      let toggled = Todo(..item, completed: !item.completed)
      ets_store.insert(id, toggled)
      #(Ok(toggled), state)
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
  case ets_store.lookup(id) {
    Error(Nil) -> #(Error(NotFound), state)
    Ok(_) -> {
      ets_store.delete(id)
      #(Ok(id), state)
    }
  }
}
