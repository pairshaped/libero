import ets_store
import server/context.{type HandlerContext}
import shared/types.{type Todo, NotFound, TitleRequired, Todo}

pub fn get_todos(
  state state: HandlerContext,
) -> #(Result(List(Todo), types.TodoError), HandlerContext) {
  #(Ok(ets_store.all()), state)
}

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
