import server/app_error.{type AppError}
import server/shared_state.{type SharedState}
import server/store
import shared/todos.{
  type MsgFromClient, type MsgFromServer, AllLoaded, Create, Created, Delete,
  Deleted, LoadAll, NotFound, TitleRequired, TodoFailed, Toggle, Toggled,
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
          let item = store.insert(title:)
          Ok(#(Created(item), state))
        }
      }
    }
    Toggle(id:) -> {
      case store.toggle(id:) {
        Ok(toggled) -> Ok(#(Toggled(toggled), state))
        Error(Nil) -> Error(NotFound)
      }
    }
    Delete(id:) -> {
      case store.delete(id:) {
        Ok(Nil) -> Ok(#(Deleted(id), state))
        Error(Nil) -> Error(NotFound)
      }
    }
    LoadAll -> Ok(#(AllLoaded(store.all()), state))
  }
}
