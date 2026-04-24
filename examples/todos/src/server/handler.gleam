import ets_store
import server/shared_state.{type SharedState}
import shared/messages.{
  type MsgFromClient, type MsgFromServer, Create, Delete, LoadAll, NotFound,
  TitleRequired, Todo, TodoCreated, TodoDeleted, TodoToggled, TodosLoaded,
  Toggle,
}

/// Handle RPC messages from clients.
pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> #(MsgFromServer, SharedState) {
  case msg {
    Create(params:) ->
      case params.title {
        "" -> #(TodoCreated(Error(TitleRequired)), state)
        title -> {
          let id = ets_store.next_id()
          let item = Todo(id:, title:, completed: False)
          ets_store.insert(id, item)
          #(TodoCreated(Ok(item)), state)
        }
      }
    Toggle(id:) ->
      case ets_store.lookup(id) {
        Error(Nil) -> #(TodoToggled(Error(NotFound)), state)
        Ok(item) -> {
          let toggled = Todo(..item, completed: !item.completed)
          ets_store.insert(id, toggled)
          #(TodoToggled(Ok(toggled)), state)
        }
      }
    Delete(id:) ->
      case ets_store.lookup(id) {
        Error(Nil) -> #(TodoDeleted(Error(NotFound)), state)
        Ok(_) -> {
          ets_store.delete(id)
          #(TodoDeleted(Ok(id)), state)
        }
      }
    LoadAll -> #(TodosLoaded(Ok(ets_store.all())), state)
  }
}
