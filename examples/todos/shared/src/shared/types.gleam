// Domain types shared between server and client. Libero's scanner checks
// that every type in a handler's signature either lives in shared/ or is a
// builtin (Int, String, Bool, List, Result, etc.). If a handler references
// a type that isn't here, it won't be exposed as an RPC endpoint.

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
