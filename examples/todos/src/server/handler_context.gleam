// HandlerContext is how Libero identifies RPC endpoints. The scanner requires
// every endpoint's last parameter to be HandlerContext and its return type to
// be #(Result(value, error), HandlerContext). The type is created once at
// server startup and threaded through every handler call, so it's the right
// place to store shared resources like database connections or caches.
//
// This example stores the todo list and an ID counter directly in the context.
// A real app might use a database connection instead:
//   HandlerContext(db: sqlight.Connection)

import shared/types.{type Todo}

pub type HandlerContext {
  HandlerContext(todos: List(Todo), next_id: Int)
}

pub fn new() -> HandlerContext {
  HandlerContext(todos: [], next_id: 1)
}
