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
  handler_ctx handler_ctx: HandlerContext,
) -> #(Result(List(Item), ItemError), HandlerContext) {
  #(Ok([]), handler_ctx)
}

pub fn create_item(
  params _params: ItemParams,
  handler_ctx handler_ctx: HandlerContext,
) -> #(Result(Item, ItemError), HandlerContext) {
  #(Error(NotFound), handler_ctx)
}

pub fn delete_item(
  id id: Int,
  handler_ctx handler_ctx: HandlerContext,
) -> #(Result(Int, ItemError), HandlerContext) {
  #(Ok(id), handler_ctx)
}

// Endpoint with Dict in params and return — exercises the Dict-as-builtin path.
pub fn lookup_items(
  ids _ids: Dict(String, Int),
  handler_ctx handler_ctx: HandlerContext,
) -> #(Result(Dict(String, Item), ItemError), HandlerContext) {
  #(Ok(dict.new()), handler_ctx)
}

// Criterion 1 missing: private function.
fn internal_helper(
  handler_ctx handler_ctx: HandlerContext,
) -> #(Result(Int, ItemError), HandlerContext) {
  #(Ok(0), handler_ctx)
}

// Criterion 2 missing: no HandlerContext parameter.
pub fn utility_function(x x: Int) -> Int {
  x + 1
}

// Bare-Result handler shape: read-only handlers may return Result(_, _)
// directly. The scanner treats this as equivalent to the tuple shape with
// an unchanged HandlerContext. Last param is still HandlerContext.
pub fn process_items(
  handler_ctx _handler_ctx: HandlerContext,
) -> Result(List(Item), ItemError) {
  Ok([])
}

// Bare-Result handler with payload params, exercising parameter handling
// on the new shape.
pub fn search_items(
  query _query: String,
  handler_ctx _handler_ctx: HandlerContext,
) -> Result(List(Item), ItemError) {
  Ok([])
}

// Criterion 3 missing (variant): HandlerContext in wrong position in tuple.
pub fn wrong_order(
  handler_ctx handler_ctx: HandlerContext,
) -> #(HandlerContext, Result(Int, ItemError)) {
  #(handler_ctx, Ok(0))
}

// Criterion 4 missing: server-only type in return.
pub fn get_audit_log(
  handler_ctx handler_ctx: HandlerContext,
) -> #(Result(AuditLog, ItemError), HandlerContext) {
  #(Ok(AuditLog), handler_ctx)
}

// Criterion 4 missing (variant): server-only type in params.
pub fn log_action(
  action _action: AuditEntry,
  handler_ctx handler_ctx: HandlerContext,
) -> #(Result(Nil, ItemError), HandlerContext) {
  #(Ok(Nil), handler_ctx)
}

// Criterion 5 missing: response is not Result(_, _). Wire envelope assumes
// Result-shaped responses, so this must be filtered out.
pub fn ping(
  handler_ctx handler_ctx: HandlerContext,
) -> #(String, HandlerContext) {
  #("pong", handler_ctx)
}

// Touch the unused private helper so Gleam doesn't warn — the helper
// exists only to test that the scanner skips private fns. This wrapper
// fails criterion 3 (Nil return), so the scanner ignores it too.
pub fn touch_internal_helper(handler_ctx handler_ctx: HandlerContext) -> Nil {
  let _ = internal_helper(handler_ctx:)
  Nil
}
