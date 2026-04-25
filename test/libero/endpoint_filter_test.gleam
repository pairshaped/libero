import gleam/list
import libero/scanner

// Four criteria for an RPC endpoint (as documented in the README):
// 1. Public function
// 2. Last parameter is HandlerContext
// 3. Returns #(Result(value, error), HandlerContext)
// 4. All types in params and return are shared (or builtins)
//
// Criterion 3 has two sub-shapes the scanner enforces independently:
//   3a. Tuple shape: #(_, HandlerContext)
//   3b. The first slot is a Result(_, _)
// The tests below split these into separate cases to isolate failures.

/// Missing criterion 1: private function
pub fn excludes_private_function_test() {
  let names = scan_fixture_names()
  let assert False = list.contains(names, "internal_helper")
}

/// Missing criterion 2: no HandlerContext parameter
pub fn excludes_no_handler_context_param_test() {
  let names = scan_fixture_names()
  let assert False = list.contains(names, "utility_function")
}

/// Missing criterion 3a: doesn't return #(_, HandlerContext)
pub fn excludes_wrong_return_shape_test() {
  let names = scan_fixture_names()
  let assert False = list.contains(names, "process_items")
}

/// Missing criterion 4: uses server-only type in return
pub fn excludes_server_only_return_type_test() {
  let names = scan_fixture_names()
  let assert False = list.contains(names, "get_audit_log")
}

/// Missing criterion 4 (variant): uses server-only type in params
pub fn excludes_server_only_param_type_test() {
  let names = scan_fixture_names()
  let assert False = list.contains(names, "log_action")
}

/// HandlerContext in wrong position in return tuple (first instead of last)
pub fn excludes_wrong_return_order_test() {
  let names = scan_fixture_names()
  let assert False = list.contains(names, "wrong_order")
}

/// Missing criterion 3b: return tuple's first element is not a Result(_, _).
/// The wire codec assumes Result-shaped responses, so a bare value in this
/// slot would compile but break serialization. Filter it out at scan time.
pub fn excludes_non_result_response_test() {
  let names = scan_fixture_names()
  let assert False = list.contains(names, "ping")
}

/// All criteria met = included
pub fn includes_valid_endpoints_test() {
  let names = scan_fixture_names()
  let assert True = list.contains(names, "get_items")
  let assert True = list.contains(names, "create_item")
  let assert True = list.contains(names, "delete_item")
}

/// Dict is a builtin and must not cause valid endpoints to be filtered out.
pub fn includes_dict_typed_endpoint_test() {
  let names = scan_fixture_names()
  let assert True = list.contains(names, "lookup_items")
}

fn scan_fixture_names() -> List(String) {
  let assert Ok(endpoints) =
    scanner.scan_handler_endpoints(
      server_src: "test/fixtures/endpoint_scan/server",
      shared_src: "test/fixtures/endpoint_scan/shared",
    )
  list.map(endpoints, fn(e) { e.fn_name })
}
