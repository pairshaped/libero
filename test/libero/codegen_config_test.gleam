//// Tests for generated config file content (WsFullUrl vs WsPathOnly).

import gleam/option.{None}
import gleam/string
import libero/codegen
import libero/config.{WsFullUrl, WsPathOnly}
import simplifile

pub fn write_config_full_url_test() {
  let output_dir = "build/.test_config_full_url"
  let cfg =
    config.build_config(
      ws_mode: WsFullUrl(url: "wss://example.com/ws"),
      namespace: None,
      client_root: output_dir,
      shared_root: Error(Nil),
      server_root: Error(Nil),
    )
  let assert Ok(Nil) = simplifile.create_directory_all(
    output_dir <> "/src/client/generated/libero",
  )
  let assert Ok(Nil) = codegen.write_config(config: cfg)

  let assert Ok(content) =
    simplifile.read(output_dir <> "/src/client/generated/libero/rpc_config.gleam")

  // Should contain the hardcoded URL
  let assert True = string.contains(content, "wss://example.com/ws")
  // Should not have the resolve function
  let assert False = string.contains(content, "resolve_ws_url")

  // No FFI file should be created for full-url mode
  let assert Error(_) =
    simplifile.read(output_dir <> "/src/client/generated/libero/rpc_config_ffi.mjs")

  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}

pub fn write_config_path_only_test() {
  let output_dir = "build/.test_config_path_only"
  let cfg =
    config.build_config(
      ws_mode: WsPathOnly(path: "/ws/admin"),
      namespace: None,
      client_root: output_dir,
      shared_root: Error(Nil),
      server_root: Error(Nil),
    )
  let assert Ok(Nil) = simplifile.create_directory_all(
    output_dir <> "/src/client/generated/libero",
  )
  let assert Ok(Nil) = codegen.write_config(config: cfg)

  let assert Ok(content) =
    simplifile.read(output_dir <> "/src/client/generated/libero/rpc_config.gleam")

  // Should reference the path
  let assert True = string.contains(content, "/ws/admin")
  // Should have the resolve function
  let assert True = string.contains(content, "resolve_ws_url")

  // FFI file should exist
  let assert Ok(ffi) =
    simplifile.read(output_dir <> "/src/client/generated/libero/rpc_config_ffi.mjs")
  let assert True = string.contains(ffi, "resolveWsUrl")
  let assert True = string.contains(ffi, "location")

  let assert Ok(Nil) = simplifile.delete_all([output_dir])
}
