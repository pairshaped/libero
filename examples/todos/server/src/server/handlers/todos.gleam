import gleam/list
import server/app_error.{type AppError}
import server/shared_state.{type SharedState, SharedState}
import shared/todos.{
  type MsgFromClient, type MsgFromServer, AllLoaded, Create, Created, Delete,
  Deleted, LoadAll, NotFound, TitleRequired, Todo, TodoFailed, Toggle, Toggled,
}

pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> Result(#(MsgFromServer, SharedState), AppError) {
  case msg {
    Create(params:) -> {
      case params.title {
        "" -> Ok(#(TodoFailed(TitleRequired), state))
        title -> {
          let new_todo = Todo(id: state.next_id, title:, completed: False)
          let new_state =
            SharedState(
              next_id: state.next_id + 1,
              todos: list.append(state.todos, [new_todo]),
            )
          Ok(#(Created(new_todo), new_state))
        }
      }
    }
    Toggle(id:) -> {
      case list.find(state.todos, fn(t) { t.id == id }) {
        Ok(found) -> {
          let toggled = Todo(..found, completed: !found.completed)
          let new_todos =
            list.map(state.todos, fn(t) {
              case t.id == id {
                True -> toggled
                False -> t
              }
            })
          Ok(#(Toggled(toggled), SharedState(..state, todos: new_todos)))
        }
        _ -> Error(NotFound)
      }
    }
    Delete(id:) -> {
      case list.find(state.todos, fn(t) { t.id == id }) {
        Ok(_) -> {
          let new_todos = list.filter(state.todos, fn(t) { t.id != id })
          Ok(#(Deleted(id), SharedState(..state, todos: new_todos)))
        }
        _ -> Error(NotFound)
      }
    }
    LoadAll -> Ok(#(AllLoaded(state.todos), state))
  }
}
