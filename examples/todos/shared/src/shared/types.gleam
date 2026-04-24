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
