import birdie
import gleam/list
import libero/codegen_dispatch
import libero/codegen_stubs
import libero/field_type
import libero/scanner
import simplifile

pub fn endpoint_dispatch_generates_client_msg_test() {
  let item_params = field_type.UserType("shared/items", "ItemParams", [])
  let endpoints = [
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "get_items",
      return_ok: field_type.IntField,
      return_err: field_type.NilField,
      params: [],
      mutates_context: True,
    ),
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "create_item",
      return_ok: field_type.IntField,
      return_err: field_type.NilField,
      params: [#("params", item_params)],
      mutates_context: True,
    ),
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "toggle_item",
      return_ok: field_type.IntField,
      return_err: field_type.NilField,
      params: [#("id", field_type.IntField)],
      mutates_context: True,
    ),
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "delete_item",
      return_ok: field_type.IntField,
      return_err: field_type.NilField,
      params: [#("id", field_type.IntField)],
      mutates_context: True,
    ),
  ]
  let output_dir = "build/.test_endpoint_dispatch"
  let assert Ok(Nil) =
    codegen_dispatch.write_endpoint_dispatch(
      endpoints: endpoints,
      server_generated: output_dir,
      atoms_module: "checklist@generated@rpc_atoms",
      context_module: "handler_context",
      wire_module_tag: "rpc",
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/dispatch.gleam")
  birdie.snap(content, title: "dispatch: four mutating endpoints")

  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}

/// Read-only handlers (mutates_context = False) return `Result(_, _)`
/// directly. The generated dispatch must wrap the call so it still feeds
/// `dispatch` the `#(_, HandlerContext)` shape it expects.
pub fn endpoint_dispatch_wraps_read_only_handler_test() {
  let endpoints = [
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "list_things",
      return_ok: field_type.IntField,
      return_err: field_type.NilField,
      params: [],
      mutates_context: False,
    ),
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "rename_thing",
      return_ok: field_type.IntField,
      return_err: field_type.NilField,
      params: [#("id", field_type.IntField)],
      mutates_context: True,
    ),
  ]
  let output_dir = "build/.test_endpoint_dispatch_read_only"
  let assert Ok(Nil) =
    codegen_dispatch.write_endpoint_dispatch(
      endpoints: endpoints,
      server_generated: output_dir,
      atoms_module: "app@generated@rpc_atoms",
      context_module: "handler_context",
      wire_module_tag: "rpc",
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/dispatch.gleam")
  birdie.snap(content, title: "dispatch: read-only handler wrapper")

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
      fn_name: "get_items",
      return_ok: field_type.IntField,
      return_err: field_type.NilField,
      params: [],
      mutates_context: True,
    ),
  ]
  let output_dir = "build/.test_endpoint_dispatch_server_only"
  let assert Ok(Nil) =
    codegen_dispatch.write_endpoint_dispatch(
      endpoints: endpoints,
      server_generated: output_dir,
      atoms_module: "checklist@generated@rpc_atoms",
      context_module: "handler_context",
      wire_module_tag: "rpc",
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/dispatch.gleam")
  birdie.snap(content, title: "dispatch: server-only constraint")

  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}

pub fn endpoint_dispatch_imports_qualified_param_types_test() {
  let endpoints = [
    scanner.HandlerEndpoint(
      module_path: "server/store",
      fn_name: "list_widgets",
      return_ok: field_type.UserType("shared/widget_detail", "Widget", []),
      return_err: field_type.NilField,
      params: [
        #("filters", field_type.UserType("shared/widgets", "WidgetFilters", [])),
      ],
      mutates_context: True,
    ),
    scanner.HandlerEndpoint(
      module_path: "server/notifier",
      fn_name: "send_alert",
      return_ok: field_type.IntField,
      return_err: field_type.NilField,
      params: [
        #("params", field_type.UserType("shared/alerts", "AlertParams", [])),
      ],
      mutates_context: True,
    ),
    scanner.HandlerEndpoint(
      module_path: "server/store",
      fn_name: "get_widget",
      return_ok: field_type.IntField,
      return_err: field_type.NilField,
      params: [#("id", field_type.IntField)],
      mutates_context: True,
    ),
  ]
  let output_dir = "build/.test_endpoint_dispatch_imports"
  let assert Ok(Nil) =
    codegen_dispatch.write_endpoint_dispatch(
      endpoints: endpoints,
      server_generated: output_dir,
      atoms_module: "app@generated@rpc_atoms",
      context_module: "handler_context",
      wire_module_tag: "shared/types",
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/dispatch.gleam")
  birdie.snap(content, title: "dispatch: qualified param type imports")

  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}

pub fn endpoint_dispatch_imports_stdlib_param_types_test() {
  let endpoints = [
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "echo_dict",
      return_ok: field_type.IntField,
      return_err: field_type.NilField,
      params: [
        #(
          "value",
          field_type.DictOf(field_type.StringField, field_type.IntField),
        ),
      ],
      mutates_context: True,
    ),
  ]
  let output_dir = "build/.test_endpoint_dispatch_stdlib_imports"
  let assert Ok(Nil) =
    codegen_dispatch.write_endpoint_dispatch(
      endpoints: endpoints,
      server_generated: output_dir,
      atoms_module: "app@generated@rpc_atoms",
      context_module: "handler_context",
      wire_module_tag: "shared/types",
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/dispatch.gleam")
  birdie.snap(content, title: "dispatch: stdlib param type imports")

  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}

pub fn endpoint_client_stubs_imports_qualified_types_test() {
  let endpoints = [
    scanner.HandlerEndpoint(
      module_path: "server/store",
      fn_name: "list_widgets",
      return_ok: field_type.UserType("shared/widgets", "WidgetList", []),
      return_err: field_type.NilField,
      params: [
        #("filters", field_type.UserType("shared/widgets", "WidgetFilters", [])),
      ],
      mutates_context: True,
    ),
    scanner.HandlerEndpoint(
      module_path: "server/notifier",
      fn_name: "send_alert",
      return_ok: field_type.UserType("shared/alerts", "AlertResult", []),
      return_err: field_type.NilField,
      params: [
        #("params", field_type.UserType("shared/alerts", "AlertParams", [])),
      ],
      mutates_context: True,
    ),
  ]
  let output_dir = "build/.test_endpoint_stubs_imports"
  let assert Ok(Nil) =
    codegen_stubs.write_endpoint_client_stubs(
      endpoints: endpoints,
      client_generated: output_dir,
      wire_module_tag: "shared/types",
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/messages.gleam")
  birdie.snap(content, title: "client stubs: qualified type imports")

  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}

pub fn endpoint_client_stubs_imports_stdlib_types_test() {
  let endpoints = [
    scanner.HandlerEndpoint(
      module_path: "server/handler",
      fn_name: "echo_dict",
      return_ok: field_type.DictOf(field_type.StringField, field_type.IntField),
      return_err: field_type.NilField,
      params: [
        #(
          "value",
          field_type.DictOf(field_type.StringField, field_type.IntField),
        ),
      ],
      mutates_context: True,
    ),
  ]
  let output_dir = "build/.test_endpoint_stubs_stdlib_imports"
  let assert Ok(Nil) =
    codegen_stubs.write_endpoint_client_stubs(
      endpoints: endpoints,
      client_generated: output_dir,
      wire_module_tag: "shared/types",
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/messages.gleam")
  birdie.snap(content, title: "client stubs: stdlib type imports")

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
      "import handler_context.{type HandlerContext}
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
  let assert field_type.UserType("shared/gadgets", "GadgetParams", []) =
    endpoint.return_ok
  let assert field_type.UserType("shared/gadgets", "GadgetError", []) =
    endpoint.return_err

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
