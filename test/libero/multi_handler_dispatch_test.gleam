import gleam/string
import libero/codegen
import libero/scanner
import simplifile

pub fn multi_handler_dispatch_per_variant_routing_test() {
  let modules = [
    scanner.MessageModule(
      module_path: "shared/messages",
      file_path: "test/fixtures/messages.gleam",
      has_msg_from_client: True,
      has_msg_from_server: True,
      handlers: [
        scanner.HandlerInfo(module_path: "server/handler_a", handled_variants: [
          "Ping",
        ]),
        scanner.HandlerInfo(module_path: "server/handler_b", handled_variants: [
          "Pong",
        ]),
      ],
    ),
  ]
  let output_dir = "build/.test_multi_handler_dispatch"
  let assert Ok(Nil) =
    codegen.write_dispatch(
      message_modules: modules,
      server_generated: output_dir,
      atoms_module: "todos@generated@rpc_atoms",
      context_module: "server/context",
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/dispatch.gleam")

  // Must import both handler modules
  let assert True =
    string.contains(
      content,
      "import server/handler_a as server_handler_a_handler",
    )
  let assert True =
    string.contains(
      content,
      "import server/handler_b as server_handler_b_handler",
    )

  // Must import the message module for typed_msg annotation
  let assert True =
    string.contains(content, "import shared/messages as shared_messages_msg")

  // Must NOT import app_error or UnhandledMessage
  let assert False = string.contains(content, "app_error")
  let assert False = string.contains(content, "UnhandledMessage")

  // Must type-annotate the coerced message
  let assert True =
    string.contains(
      content,
      "let typed_msg: shared_messages_msg.MsgFromClient = wire.coerce(msg)",
    )

  // Must have per-variant routing patterns
  let assert True = string.contains(content, "shared_messages_msg.Ping(..)")
  let assert True = string.contains(content, "shared_messages_msg.Pong(..)")

  // Must route each variant to the correct handler
  let assert True =
    string.contains(
      content,
      "server_handler_a_handler.update_from_client(msg: typed_msg, state:)",
    )
  let assert True =
    string.contains(
      content,
      "server_handler_b_handler.update_from_client(msg: typed_msg, state:)",
    )

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}

pub fn single_handler_no_chain_test() {
  let modules = [
    scanner.MessageModule(
      module_path: "shared/messages",
      file_path: "test/fixtures/messages.gleam",
      has_msg_from_client: True,
      has_msg_from_server: True,
      handlers: [
        scanner.HandlerInfo(module_path: "server/handler", handled_variants: [
          "Ping",
        ]),
      ],
    ),
  ]
  let output_dir = "build/.test_single_handler_dispatch"
  let assert Ok(Nil) =
    codegen.write_dispatch(
      message_modules: modules,
      server_generated: output_dir,
      atoms_module: "todos@generated@rpc_atoms",
      context_module: "server/context",
    )
  let assert Ok(content) = simplifile.read(output_dir <> "/dispatch.gleam")

  // Single handler should NOT import UnhandledMessage or app_error
  let assert False = string.contains(content, "UnhandledMessage")
  let assert False = string.contains(content, "app_error")

  // Should use simple dispatch without typed_msg annotation
  let assert False = string.contains(content, "typed_msg")

  // Cleanup
  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}
