// Fixture for endpoint scanner tests.
// Covers each criterion the scanner enforces, plus the negative cases where
// one criterion is intentionally violated. Types are defined locally so the
// fixture compiles standalone under `gleam test`. The scanner determines what
// counts as "shared" by reading test/fixtures/endpoint_scan/shared/items.gleam,
// which exports the same type names by design.

import gleam/dict.{type Dict}

pub type HandlerContext {
  HandlerContext
}

// Names that match the shared fixture (test/fixtures/endpoint_scan/shared/items.gleam)
// so the scanner accepts them as shared.
pub type Item {
  Item(id: Int, name: String)
}

pub type ItemParams {
  ItemParams(name: String)
}

pub type ItemError {
  NotFound
  Invalid
}

// Server-only types — present so we can reference them in negative cases
// without polluting the shared/ tree.
pub type AuditLog {
  AuditLog
}

pub type AuditEntry {
  AuditEntry
}

// All criteria met — included as endpoints.

pub fn get_items(
  state state: HandlerContext,
) -> #(Result(List(Item), ItemError), HandlerContext) {
  #(Ok([]), state)
}

pub fn create_item(
  params _params: ItemParams,
  state state: HandlerContext,
) -> #(Result(Item, ItemError), HandlerContext) {
  #(Error(NotFound), state)
}

pub fn delete_item(
  id id: Int,
  state state: HandlerContext,
) -> #(Result(Int, ItemError), HandlerContext) {
  #(Ok(id), state)
}

// Endpoint with Dict in params and return — exercises the Dict-as-builtin path.
pub fn lookup_items(
  ids _ids: Dict(String, Int),
  state state: HandlerContext,
) -> #(Result(Dict(String, Item), ItemError), HandlerContext) {
  #(Ok(dict.new()), state)
}

// Criterion 1 missing: private function.
fn internal_helper(
  state state: HandlerContext,
) -> #(Result(Int, ItemError), HandlerContext) {
  #(Ok(0), state)
}

// Criterion 2 missing: no HandlerContext parameter.
pub fn utility_function(x x: Int) -> Int {
  x + 1
}

// Criterion 3 missing: return is not a #(_, HandlerContext) tuple.
pub fn process_items(
  state _state: HandlerContext,
) -> Result(List(Item), ItemError) {
  Ok([])
}

// Criterion 3 missing (variant): HandlerContext in wrong position in tuple.
pub fn wrong_order(
  state state: HandlerContext,
) -> #(HandlerContext, Result(Int, ItemError)) {
  #(state, Ok(0))
}

// Criterion 4 missing: server-only type in return.
pub fn get_audit_log(
  state state: HandlerContext,
) -> #(Result(AuditLog, ItemError), HandlerContext) {
  #(Ok(AuditLog), state)
}

// Criterion 4 missing (variant): server-only type in params.
pub fn log_action(
  action _action: AuditEntry,
  state state: HandlerContext,
) -> #(Result(Nil, ItemError), HandlerContext) {
  #(Ok(Nil), state)
}

// Criterion 5 missing: response is not Result(_, _). Wire envelope assumes
// Result-shaped responses, so this must be filtered out.
pub fn ping(state state: HandlerContext) -> #(String, HandlerContext) {
  #("pong", state)
}

// Old-convention handler — must be skipped even though it superficially
// matches criteria 1-4.
pub fn update_from_client(
  msg _msg: ItemError,
  state state: HandlerContext,
) -> #(Result(Nil, ItemError), HandlerContext) {
  #(Ok(Nil), state)
}

// Touch the unused private helper so Gleam doesn't warn — the helper
// exists only to test that the scanner skips private fns. This wrapper
// fails criterion 3 (Nil return), so the scanner ignores it too.
pub fn touch_internal_helper(state state: HandlerContext) -> Nil {
  let _ = internal_helper(state:)
  Nil
}
