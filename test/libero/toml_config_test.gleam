//// Tests for the TOML config parser.

import gleam/list
import gleam/option.{Some}
import gleam/string
import libero/config.{WsPathOnly}
import libero/toml_config.{type ClientConfig, ClientConfig, TomlConfig}

pub fn parse_minimal_toml_test() {
  let toml = "name = \"myapp\"\n\n[tools.libero]\nport = 3000\n"
  let assert Ok(cfg) = toml_config.parse(toml)
  let assert "myapp" = cfg.name
  let assert 3000 = cfg.port
  let assert False = cfg.rest
  let assert [] = cfg.clients
}

pub fn parse_uses_shared_plus_server_defaults_test() {
  // No tools.libero overrides -> defaults assume shared + server + clients layout
  let toml = "name = \"myapp\"\n"
  let assert Ok(cfg) = toml_config.parse(toml)
  let assert "src" = cfg.server_src_dir
  let assert "src/server/generated" = cfg.server_generated_dir
  let assert "shared/src/shared" = cfg.shared_src_dir
  let assert "server/shared_state" = cfg.shared_state_module
  let assert "server/app_error" = cfg.app_error_module
  let assert "src/myapp@generated@rpc_atoms.erl" = cfg.server_atoms_path
}

pub fn parse_with_clients_test() {
  let toml =
    "name = \"myapp\"\n\n[tools.libero.server]\nrest = true\n\n[tools.libero.clients.web]\ntarget = \"javascript\"\n\n[tools.libero.clients.cli]\ntarget = \"erlang\"\n"
  let assert Ok(cfg) = toml_config.parse(toml)
  let assert "myapp" = cfg.name
  let assert 8080 = cfg.port
  let assert True = cfg.rest
  let assert 2 = list.length(cfg.clients)
  let assert True =
    list.any(cfg.clients, fn(c: ClientConfig) {
      c.name == "web" && c.target == "javascript"
    })
  let assert True =
    list.any(cfg.clients, fn(c: ClientConfig) {
      c.name == "cli" && c.target == "erlang"
    })
}

pub fn parse_no_tools_libero_section_test() {
  let toml = "name = \"myapp\"\n"
  let assert Ok(cfg) = toml_config.parse(toml)
  let assert "myapp" = cfg.name
  let assert 8080 = cfg.port
  let assert False = cfg.rest
  let assert [] = cfg.clients
}

pub fn parse_missing_name_test() {
  let toml = "[tools.libero]\nport = 9090\n"
  let assert Error(msg) = toml_config.parse(toml)
  let assert "missing required field: name" = msg
}

pub fn parse_rejects_legacy_libero_section_test() {
  let toml = "name = \"myapp\"\n\n[libero]\nport = 3000\n"
  let assert Error(msg) = toml_config.parse(toml)
  let assert True =
    string.contains(msg, "must be under [tools.libero]")
}

pub fn to_codegen_config_javascript_client_test() {
  let toml_cfg =
    TomlConfig(
      name: "my_app",
      port: 3000,
      rest: False,
      clients: [ClientConfig(name: "web", target: "javascript")],
      server_src_dir: "src",
      server_generated_dir: "src/server/generated",
      server_atoms_path: "src/my_app@generated@rpc_atoms.erl",
      shared_src_dir: "shared/src/shared",
      shared_state_module: "server/shared_state",
      app_error_module: "server/app_error",
    )
  let assert Ok(cfg) =
    toml_config.to_codegen_config(toml_cfg, client: "web", ws_path: "/ws")
  let assert "clients/web/src/generated" = cfg.client_generated
  let assert "src/server/generated" = cfg.server_generated
  let assert Some("shared/src/shared") = cfg.shared_src
  let assert WsPathOnly(path: "/ws") = cfg.ws_mode
}

pub fn to_codegen_config_missing_client_test() {
  let toml_cfg =
    TomlConfig(
      name: "my_app",
      port: 3000,
      rest: False,
      clients: [],
      server_src_dir: "src",
      server_generated_dir: "src/server/generated",
      server_atoms_path: "src/my_app@generated@rpc_atoms.erl",
      shared_src_dir: "shared/src/shared",
      shared_state_module: "server/shared_state",
      app_error_module: "server/app_error",
    )
  let assert Error("client not found: web") =
    toml_config.to_codegen_config(toml_cfg, client: "web", ws_path: "/ws")
}
