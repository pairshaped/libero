//// TOML configuration parser for Libero v4.
////
//// Parses a `libero.toml` string into a `TomlConfig` record.

import gleam/dict
import gleam/list
import gleam/result
import tom

// ---------- Types ----------

pub type ClientConfig {
  ClientConfig(name: String, target: String)
}

pub type TomlConfig {
  TomlConfig(name: String, port: Int, rest: Bool, clients: List(ClientConfig))
}

// ---------- Public API ----------

/// Parse a TOML string into a `TomlConfig`.
///
/// Returns `Error(String)` for parse failures or missing required fields.
pub fn parse(input: String) -> Result(TomlConfig, String) {
  use parsed <- result.try(
    tom.parse(input) |> result.map_error(fn(_) { "invalid TOML" }),
  )

  use name <- result.try(
    tom.get_string(parsed, ["name"])
    |> result.map_error(fn(_) { "missing required field: name" }),
  )

  let port =
    tom.get_int(parsed, ["port"]) |> result.unwrap(8080)

  let rest =
    tom.get_bool(parsed, ["server", "rest"]) |> result.unwrap(False)

  use clients <- result.try(parse_clients(parsed))

  Ok(TomlConfig(name: name, port: port, rest: rest, clients: clients))
}

// ---------- Private helpers ----------

fn parse_clients(
  parsed: dict.Dict(String, tom.Toml),
) -> Result(List(ClientConfig), String) {
  case tom.get_table(parsed, ["clients"]) {
    Error(_) -> Ok([])
    Ok(clients_dict) -> {
      let names = dict.keys(clients_dict)
      list.try_map(names, fn(name) {
        use client_table <- result.try(
          tom.get_table(clients_dict, [name])
          |> result.map_error(fn(_) {
            "invalid clients." <> name <> " section"
          }),
        )
        use target <- result.try(
          tom.get_string(client_table, ["target"])
          |> result.map_error(fn(_) {
            "missing target in clients." <> name
          }),
        )
        Ok(ClientConfig(name: name, target: target))
      })
    }
  }
}
