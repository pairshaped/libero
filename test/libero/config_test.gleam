//// Tests for config path derivation logic.

import gleam/option.{None, Some}
import libero/config.{WsPathOnly}

pub fn build_config_no_namespace_paths_test() {
  let cfg =
    config.build_config(
      ws_mode: WsPathOnly(path: "/ws"),
      namespace: None,
      client_root: "../client",
      shared_root: Ok("../shared"),
      server_root: Ok("."),
    )
  let assert "src/server@generated@libero@rpc_atoms.erl" = cfg.atoms_output
  let assert "server@generated@libero@rpc_atoms" = cfg.atoms_module
  let assert "../client/src/client/generated/libero/rpc_config.gleam" =
    cfg.config_output
  let assert "../../../../" = cfg.register_relpath_prefix
  let assert "src/server/generated/libero" = cfg.server_generated
  let assert "../client/src/client/generated/libero" = cfg.client_generated
  let assert Some("../shared/src/shared") = cfg.shared_src
  let assert Some("./src") = cfg.server_src
}

pub fn build_config_with_namespace_paths_test() {
  let cfg =
    config.build_config(
      ws_mode: WsPathOnly(path: "/ws/admin"),
      namespace: Some("admin"),
      client_root: "../client",
      shared_root: Ok("../shared"),
      server_root: Ok("."),
    )
  let assert "src/server@generated@libero@admin@rpc_atoms.erl" =
    cfg.atoms_output
  let assert "server@generated@libero@admin@rpc_atoms" = cfg.atoms_module
  let assert "../client/src/client/generated/libero/admin/rpc_config.gleam" =
    cfg.config_output
  let assert "../../../../../" = cfg.register_relpath_prefix
  let assert "src/server/generated/libero/admin" = cfg.server_generated
  let assert "../client/src/client/generated/libero/admin" =
    cfg.client_generated
}

pub fn build_config_custom_client_root_test() {
  let cfg =
    config.build_config(
      ws_mode: WsPathOnly(path: "/ws"),
      namespace: None,
      client_root: "packages/frontend",
      shared_root: Ok("../shared"),
      server_root: Ok("."),
    )
  let assert "packages/frontend/src/client/generated/libero/rpc_config.gleam" =
    cfg.config_output
  let assert "packages/frontend/src/client/generated/libero" =
    cfg.client_generated
}

pub fn build_config_no_shared_or_server_test() {
  let cfg =
    config.build_config(
      ws_mode: WsPathOnly(path: "/ws"),
      namespace: None,
      client_root: "../client",
      shared_root: Error(Nil),
      server_root: Error(Nil),
    )
  let assert None = cfg.shared_src
  let assert None = cfg.server_src
}
