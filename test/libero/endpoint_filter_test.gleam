import gleam/list
import libero/scanner

// Four criteria for an RPC endpoint:
// 1. Public function
// 2. Last parameter is HandlerContext
// 3. Return type is #(something, HandlerContext)
// 4. All types in params and return are shared (or builtins)
//
// Each test below has 3 of 4 criteria met, with one missing.

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

/// Missing criterion 3: doesn't return #(something, HandlerContext)
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

/// Skips old convention (update_from_client)
pub fn excludes_update_from_client_test() {
  let names = scan_fixture_names()
  let assert False = list.contains(names, "update_from_client")
}

/// All 4 criteria met = included
pub fn includes_valid_endpoints_test() {
  let names = scan_fixture_names()
  let assert True = list.contains(names, "get_items")
  let assert True = list.contains(names, "create_item")
  let assert True = list.contains(names, "delete_item")
}

fn scan_fixture_names() -> List(String) {
  let assert Ok(endpoints) =
    scanner.scan_handler_endpoints(
      server_src: "build/.test_fixtures/endpoint_scan/server",
      shared_src: "build/.test_fixtures/endpoint_scan/shared",
    )
  list.map(endpoints, fn(e) { e.fn_name })
}
