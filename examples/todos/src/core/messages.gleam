pub type Todo {
  Todo(id: Int, title: String, completed: Bool)
}

pub type TodoParams {
  TodoParams(title: String)
}

pub type TodoError {
  NotFound
  TitleRequired
}

pub type MsgFromClient {
  Create(params: TodoParams)
  Toggle(id: Int)
  Delete(id: Int)
  LoadAll
}

pub type MsgFromServer {
  TodoCreated(Result(Todo, TodoError))
  TodoToggled(Result(Todo, TodoError))
  TodoDeleted(Result(Int, TodoError))
  TodosLoaded(Result(List(Todo), TodoError))
}
