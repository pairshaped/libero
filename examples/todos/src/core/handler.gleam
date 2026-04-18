import core/app_error.{type AppError}
import core/messages.{
  type MsgFromClient, type MsgFromServer, Create, Delete, LoadAll, NotFound,
  TitleRequired, Todo, TodoCreated, TodoDeleted, TodoToggled, TodosLoaded,
  Toggle,
}
import core/shared_state.{type SharedState}
import ets_store

/// Handle RPC messages from clients.
pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> Result(#(MsgFromServer, SharedState), AppError) {
  case msg {
    Create(params:) ->
      case params.title {
        "" -> Ok(#(TodoCreated(Error(TitleRequired)), state))
        title -> {
          let id = ets_store.next_id()
          let item = Todo(id:, title:, completed: False)
          ets_store.insert(id, item)
          Ok(#(TodoCreated(Ok(item)), state))
        }
      }
    Toggle(id:) ->
      case ets_store.lookup(id) {
        Error(Nil) -> Ok(#(TodoToggled(Error(NotFound)), state))
        Ok(item) -> {
          let toggled = Todo(..item, completed: !item.completed)
          ets_store.insert(id, toggled)
          Ok(#(TodoToggled(Ok(toggled)), state))
        }
      }
    Delete(id:) ->
      case ets_store.lookup(id) {
        Error(Nil) -> Ok(#(TodoDeleted(Error(NotFound)), state))
        Ok(_) -> {
          ets_store.delete(id)
          Ok(#(TodoDeleted(Ok(id)), state))
        }
      }
    LoadAll -> Ok(#(TodosLoaded(Ok(ets_store.all())), state))
  }
}
