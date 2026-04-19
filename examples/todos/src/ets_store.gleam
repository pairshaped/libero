//// Thin wrapper around an ETS named table for storing todos.

import shared/messages.{type Todo}

/// Create the ETS table. Call once at startup.
@external(erlang, "todos_ets_ffi", "init")
pub fn init() -> Nil

/// Insert a todo by its ID.
@external(erlang, "todos_ets_ffi", "insert")
pub fn insert(id: Int, item: Todo) -> Nil

/// Look up a todo by ID.
@external(erlang, "todos_ets_ffi", "lookup")
pub fn lookup(id: Int) -> Result(Todo, Nil)

/// Delete a todo by ID.
@external(erlang, "todos_ets_ffi", "delete")
pub fn delete(id: Int) -> Nil

/// Return all todos.
@external(erlang, "todos_ets_ffi", "all")
pub fn all() -> List(Todo)

/// Return the next auto-increment ID (current size + 1).
@external(erlang, "todos_ets_ffi", "next_id")
pub fn next_id() -> Int
