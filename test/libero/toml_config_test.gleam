//// Tests for the TOML config parser.

import gleam/list
import libero/toml_config.{type ClientConfig}

pub fn parse_minimal_toml_test() {
  let toml = "name = \"myapp\"\nport = 3000\n"
  let assert Ok(cfg) = toml_config.parse(toml)
  let assert "myapp" = cfg.name
  let assert 3000 = cfg.port
  let assert False = cfg.rest
  let assert [] = cfg.clients
}

pub fn parse_with_clients_test() {
  let toml =
    "name = \"myapp\"\n\n[server]\nrest = true\n\n[clients.web]\ntarget = \"javascript\"\n\n[clients.cli]\ntarget = \"erlang\"\n"
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

pub fn parse_missing_name_test() {
  let toml = "port = 9090\n"
  let assert Error(msg) = toml_config.parse(toml)
  let assert "missing required field: name" = msg
}
