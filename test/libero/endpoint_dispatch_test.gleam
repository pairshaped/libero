import gleam/list
import gleam/string
import libero/codegen
import libero/field_type
import libero/scanner
import simplifile

pub fn endpoint_dispatch_generates_client_msg_test() {
  let endpoints = [
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "get_todos",
      return_type: field_type.placeholder(),
      params: [],
      params_str: [],
      return_type_str: "Result(List(Todo), TodoError)",
    ),
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "create_todo",
      return_type: field_type.placeholder(),
      params: [#("params", field_type.placeholder())],
      params_str: [#("params", "TodoParams")],
      return_type_str: "Result(Todo, TodoError)",
    ),
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "toggle_todo",
      return_type: field_type.placeholder(),
      params: [#("id", field_type.placeholder())],
      params_str: [#("id", "Int")],
      return_type_str: "Result(Todo, TodoError)",
    ),
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "delete_todo",
      return_type: field_type.placeholder(),
      params: [#("id", field_type.placeholder())],
      params_str: [#("id", "Int")],
      return_type_str: "Result(Int, TodoError)",
    ),
  ]
  let output_dir = "build/.test_endpoint_dispatch"
  let assert Ok(Nil) =
    codegen.write_endpoint_dispatch(
      endpoints: endpoints,
      server_generated: output_dir,
      atoms_module: "todos@generated@rpc_atoms",
      context_module: "server/handler_context",
      shared_module_path: "shared/messages",
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/dispatch.gleam")

  // Must have ClientMsg type with all variants
  let assert True = string.contains(content, "pub type ClientMsg {")
  let assert True = string.contains(content, "GetTodos")
  let assert True = string.contains(content, "CreateTodo(params: TodoParams)")
  let assert True = string.contains(content, "ToggleTodo(id: Int)")
  let assert True = string.contains(content, "DeleteTodo(id: Int)")

  // Must route to handler functions
  let assert True = string.contains(content, "handler.get_todos(state:)")
  let assert True =
    string.contains(content, "handler.create_todo(params:, state:)")
  let assert True = string.contains(content, "handler.toggle_todo(id:, state:)")
  let assert True = string.contains(content, "handler.delete_todo(id:, state:)")

  // Must NOT reference AppError or MsgFromServer
  let assert False = string.contains(content, "AppError")
  let assert False = string.contains(content, "MsgFromServer")

  // UnknownFunction must pass through the caller's request_id so the
  // client can correlate the error to its in-flight call.
  let assert True = string.contains(content, "Ok(#(name, request_id, _))")
  let assert False = string.contains(content, "Ok(#(name, _request_id, _))")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}

/// dispatch.gleam declares `ensure_atoms` as an Erlang-only external with no
/// JS fallback. That fails JS compilation at the unresolved-external
/// boundary, which is the signal that this module is server-only. The doc
/// comment at the top of the file calls this out so a reader knows why.
pub fn endpoint_dispatch_is_server_only_test() {
  let endpoints = [
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "get_todos",
      return_type: field_type.placeholder(),
      params: [],
      params_str: [],
      return_type_str: "Result(List(Todo), TodoError)",
    ),
  ]
  let output_dir = "build/.test_endpoint_dispatch_server_only"
  let assert Ok(Nil) =
    codegen.write_endpoint_dispatch(
      endpoints: endpoints,
      server_generated: output_dir,
      atoms_module: "todos@generated@rpc_atoms",
      context_module: "server/handler_context",
      shared_module_path: "shared/messages",
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/dispatch.gleam")

  // Erlang-only external naturally restricts the module to the Erlang target.
  let assert True = string.contains(content, "@external(erlang,")
  let assert False = string.contains(content, "@external(javascript,")
  // Doc comment explains the constraint to readers.
  let assert True = string.contains(content, "Server-only")

  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}

pub fn endpoint_dispatch_imports_qualified_param_types_test() {
  // When handler params reference module-qualified types (e.g.,
  // widgets.WidgetParams), the generated dispatch must import those
  // modules so the ClientMsg enum compiles.
  let endpoints = [
    scanner.HandlerEndpoint(
      module_path: "server/store",
      fn_name: "list_widgets",
      return_type: field_type.placeholder(),
      params: [#("filters", field_type.placeholder())],
      params_str: [#("filters", "widgets.WidgetFilters")],
      return_type_str: "Result(widgets.WidgetList, widgets.WidgetError)",
    ),
    scanner.HandlerEndpoint(
      module_path: "server/notifier",
      fn_name: "send_alert",
      return_type: field_type.placeholder(),
      params: [#("params", field_type.placeholder())],
      params_str: [#("params", "alerts.AlertParams")],
      return_type_str: "Result(alerts.AlertResult, alerts.AlertError)",
    ),
    scanner.HandlerEndpoint(
      module_path: "server/store",
      fn_name: "get_widget",
      return_type: field_type.placeholder(),
      params: [#("id", field_type.placeholder())],
      params_str: [#("id", "Int")],
      return_type_str: "Result(widget_detail.Widget, String)",
    ),
  ]
  let output_dir = "build/.test_endpoint_dispatch_imports"
  let assert Ok(Nil) =
    codegen.write_endpoint_dispatch(
      endpoints: endpoints,
      server_generated: output_dir,
      atoms_module: "app@generated@rpc_atoms",
      context_module: "server/handler_context",
      shared_module_path: "shared/types",
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/dispatch.gleam")

  // Must import shared modules referenced in param types
  let assert True = string.contains(content, "import shared/widgets")
  let assert True = string.contains(content, "import shared/alerts")

  // Must NOT import builtins (Int, String, List, Option, Bool)
  let assert False = string.contains(content, "import shared/Int")

  // Dispatch does NOT import modules only referenced in return types
  // (return types flow through wire.encode at runtime, not static references).
  // Client stubs DO import them for RemoteData annotations.
  let assert False = string.contains(content, "import shared/widget_detail")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}

pub fn endpoint_dispatch_imports_stdlib_param_types_test() {
  let endpoints = [
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "echo_dict",
      return_type: field_type.placeholder(),
      params: [#("value", field_type.placeholder())],
      params_str: [#("value", "Dict(String, Int)")],
      return_type_str: "Result(Dict(String, Int), Nil)",
    ),
  ]
  let output_dir = "build/.test_endpoint_dispatch_stdlib_imports"
  let assert Ok(Nil) =
    codegen.write_endpoint_dispatch(
      endpoints: endpoints,
      server_generated: output_dir,
      atoms_module: "app@generated@rpc_atoms",
      context_module: "server/handler_context",
      shared_module_path: "shared/types",
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/dispatch.gleam")

  let assert True = string.contains(content, "import gleam/dict.{type Dict}")
  let assert True =
    string.contains(content, "EchoDict(value: Dict(String, Int))")

  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}

pub fn endpoint_client_stubs_imports_qualified_types_test() {
  // Same bug applies to generated client stubs (messages.gleam)
  let endpoints = [
    scanner.HandlerEndpoint(
      module_path: "server/store",
      fn_name: "list_widgets",
      return_type: field_type.placeholder(),
      params: [#("filters", field_type.placeholder())],
      params_str: [#("filters", "widgets.WidgetFilters")],
      return_type_str: "Result(widgets.WidgetList, widgets.WidgetError)",
    ),
    scanner.HandlerEndpoint(
      module_path: "server/notifier",
      fn_name: "send_alert",
      return_type: field_type.placeholder(),
      params: [#("params", field_type.placeholder())],
      params_str: [#("params", "alerts.AlertParams")],
      return_type_str: "Result(alerts.AlertResult, alerts.AlertError)",
    ),
  ]
  let output_dir = "build/.test_endpoint_stubs_imports"
  let assert Ok(Nil) =
    codegen.write_endpoint_client_stubs(
      endpoints: endpoints,
      client_generated: output_dir,
      shared_module_path: "shared/types",
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/messages.gleam")

  // Must import shared modules referenced in param and return types
  let assert True = string.contains(content, "import shared/widgets")
  let assert True = string.contains(content, "import shared/alerts")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}

pub fn endpoint_client_stubs_imports_stdlib_types_test() {
  let endpoints = [
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "echo_dict",
      return_type: field_type.placeholder(),
      params: [#("value", field_type.placeholder())],
      params_str: [#("value", "Dict(String, Int)")],
      return_type_str: "Result(Dict(String, Int), Nil)",
    ),
  ]
  let output_dir = "build/.test_endpoint_stubs_stdlib_imports"
  let assert Ok(Nil) =
    codegen.write_endpoint_client_stubs(
      endpoints: endpoints,
      client_generated: output_dir,
      shared_module_path: "shared/types",
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/messages.gleam")

  let assert True = string.contains(content, "import gleam/dict.{type Dict}")
  let assert True =
    string.contains(content, "EchoDict(value: Dict(String, Int))")
  let assert True = string.contains(content, "value value: Dict(String, Int),")

  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}

pub fn scanner_resolves_import_aliases_in_type_annotations_test() {
  // When a handler file uses `import shared/widgets as w`, the scanner
  // should emit types as "widgets.WidgetParams", not "w.WidgetParams".
  // This test creates a fixture handler with an aliased import and verifies
  // the scanner resolves it.
  let fixture_dir = "build/.test_alias_resolution"
  let server_dir = fixture_dir <> "/server"
  let shared_dir = fixture_dir <> "/shared"
  let assert Ok(Nil) = simplifile.create_directory_all(server_dir)
  let assert Ok(Nil) = simplifile.create_directory_all(shared_dir)

  // Shared type module
  let assert Ok(Nil) =
    simplifile.write(
      shared_dir <> "/gadgets.gleam",
      "pub type GadgetParams { GadgetParams(name: String) }
pub type GadgetError { GadgetNotFound }
",
    )

  // Handler that uses an alias
  let assert Ok(Nil) =
    simplifile.write(
      server_dir <> "/store.gleam",
      "import server/handler_context.{type HandlerContext}
import shared/gadgets as g

pub fn create_gadget(
  params params: g.GadgetParams,
  state state: HandlerContext,
) -> #(Result(g.GadgetParams, g.GadgetError), HandlerContext) {
  #(Ok(params), state)
}
",
    )

  let assert Ok(endpoints) =
    scanner.scan_handler_endpoints(
      server_src: server_dir,
      shared_src: shared_dir,
    )

  let assert [endpoint] = endpoints
  let assert "create_gadget" = endpoint.fn_name

  // Structured form must resolve the alias to the real module path.
  let assert [
    #("params", field_type.UserType("shared/gadgets", "GadgetParams", [])),
  ] = endpoint.params
  let assert field_type.ResultOf(
    ok: field_type.UserType("shared/gadgets", "GadgetParams", []),
    err: field_type.UserType("shared/gadgets", "GadgetError", []),
  ) = endpoint.return_type

  // String-form (kept for codegen compatibility) also resolves the alias.
  let assert [#("params", type_str)] = endpoint.params_str
  let assert True = string.contains(type_str, "gadgets.GadgetParams")
  let assert False = string.contains(type_str, "g.GadgetParams")
  let assert True = string.contains(endpoint.return_type_str, "gadgets.")
  let assert False = string.contains(endpoint.return_type_str, "g.")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([fixture_dir])
}

pub fn scan_fixture_handler_endpoints_test() {
  // Integration check against the committed fixture handler. Lives separately
  // from endpoint_filter_test so we exercise the labelled-param shape coming
  // out of the scanner, not just the names.
  let assert Ok(endpoints) =
    scanner.scan_handler_endpoints(
      server_src: "test/fixtures/endpoint_scan/server",
      shared_src: "test/fixtures/endpoint_scan/shared",
    )
  let names = list.map(endpoints, fn(e) { e.fn_name })
  let assert True = list.contains(names, "get_items")
  let assert True = list.contains(names, "create_item")
  let assert True = list.contains(names, "delete_item")

  // create_item should have one labelled param
  let assert Ok(create) =
    list.find(endpoints, fn(e) { e.fn_name == "create_item" })
  let assert [#("params", _type)] = create.params

  // get_items should have no params (only state)
  let assert Ok(get) = list.find(endpoints, fn(e) { e.fn_name == "get_items" })
  let assert True = list.is_empty(get.params)
}
