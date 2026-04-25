import gleam/list
import gleam/string
import libero/codegen
import libero/scanner
import simplifile

pub fn endpoint_dispatch_generates_client_msg_test() {
  let endpoints = [
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "get_todos",
      params: [],
      return_type_str: "Result(List(Todo), TodoError)",
    ),
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "create_todo",
      params: [#("params", "TodoParams")],
      return_type_str: "Result(Todo, TodoError)",
    ),
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "toggle_todo",
      params: [#("id", "Int")],
      return_type_str: "Result(Todo, TodoError)",
    ),
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "delete_todo",
      params: [#("id", "Int")],
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

  // Cleanup
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
      params: [#("filters", "widgets.WidgetFilters")],
      return_type_str: "Result(widgets.WidgetList, widgets.WidgetError)",
    ),
    scanner.HandlerEndpoint(
      module_path: "server/notifier",
      fn_name: "send_alert",
      params: [#("params", "alerts.AlertParams")],
      return_type_str: "Result(alerts.AlertResult, alerts.AlertError)",
    ),
    scanner.HandlerEndpoint(
      module_path: "server/store",
      fn_name: "get_widget",
      params: [#("id", "Int")],
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

  // Modules only referenced in return types also need imports
  let assert True = string.contains(content, "import shared/widget_detail")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}

pub fn endpoint_client_stubs_imports_qualified_types_test() {
  // Same bug applies to generated client stubs (messages.gleam)
  let endpoints = [
    scanner.HandlerEndpoint(
      module_path: "server/store",
      fn_name: "list_widgets",
      params: [#("filters", "widgets.WidgetFilters")],
      return_type_str: "Result(widgets.WidgetList, widgets.WidgetError)",
    ),
    scanner.HandlerEndpoint(
      module_path: "server/notifier",
      fn_name: "send_alert",
      params: [#("params", "alerts.AlertParams")],
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

pub fn scan_todos_handler_endpoints_test() {
  // Scan the actual todos example handler
  let assert Ok(endpoints) =
    scanner.scan_handler_endpoints(
      server_src: "examples/todos/src",
      shared_src: "examples/todos/shared/src/shared",
    )
  // Should find 4 endpoints: get_todos, create_todo, toggle_todo, delete_todo
  let names = list.map(endpoints, fn(e) { e.fn_name })
  let assert True = list.contains(names, "get_todos")
  let assert True = list.contains(names, "create_todo")
  let assert True = list.contains(names, "toggle_todo")
  let assert True = list.contains(names, "delete_todo")

  // create_todo should have params
  let assert Ok(create) =
    list.find(endpoints, fn(e) { e.fn_name == "create_todo" })
  let assert True = list.length(create.params) == 1
  let assert [#("params", _type_str)] = create.params

  // get_todos should have no params (only state)
  let assert Ok(get) = list.find(endpoints, fn(e) { e.fn_name == "get_todos" })
  let assert True = list.is_empty(get.params)
}
