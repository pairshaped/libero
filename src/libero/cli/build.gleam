//// `libero build` — gen + build server + build all clients.

import gleam/io
import gleam/list
import libero/cli/gen
import libero/toml_config
import simplifile

/// Run gen, then build the server and each client package.
pub fn run(project_path project_path: String) -> Result(Nil, String) {
  // 1. Run gen
  use _ <- try(gen.run(project_path:))

  // 2. Build server (root package)
  io.println("libero: building server...")
  let exit_code = gleam_build(project_path)
  use _ <- try(case exit_code {
    0 -> Ok(Nil)
    _ -> Error("server build failed")
  })

  // 3. Read config to find clients
  use toml_content <- try_read(project_path <> "/gleam.toml")
  use toml_cfg <- try_parse(toml_content)

  // 4. Build each client
  let client_results =
    list.try_map(toml_cfg.clients, fn(client) {
      let client_dir = project_path <> "/clients/" <> client.name
      case simplifile.is_directory(client_dir) {
        Ok(True) -> {
          io.println("libero: building client: " <> client.name <> "...")
          let code = gleam_build(client_dir)
          case code {
            0 -> Ok(Nil)
            _ -> Error("client " <> client.name <> " build failed")
          }
        }
        _ -> {
          io.println(
            "libero: skipping client "
            <> client.name
            <> " (directory not found)",
          )
          Ok(Nil)
        }
      }
    })
  use _ <- try(case client_results {
    Ok(_) -> Ok(Nil)
    Error(msg) -> Error(msg)
  })

  io.println("libero: build complete")
  Ok(Nil)
}

fn try(
  result: Result(Nil, String),
  next: fn(Nil) -> Result(Nil, String),
) -> Result(Nil, String) {
  case result {
    Ok(Nil) -> next(Nil)
    Error(msg) -> Error(msg)
  }
}

fn try_read(
  path: String,
  next: fn(String) -> Result(Nil, String),
) -> Result(Nil, String) {
  case simplifile.read(path) {
    Ok(content) -> next(content)
    Error(_) -> Error("cannot read " <> path)
  }
}

fn try_parse(
  content: String,
  next: fn(toml_config.TomlConfig) -> Result(Nil, String),
) -> Result(Nil, String) {
  case toml_config.parse(content) {
    Ok(cfg) -> next(cfg)
    Error(msg) -> Error(msg)
  }
}

fn return_error(msg: String) -> Result(Nil, String) {
  Error(msg)
}

fn gleam_build(dir: String) -> Int {
  ffi_run_command(dir, ["build"])
}

@external(erlang, "libero_cli_ffi", "run_command")
fn ffi_run_command(dir: String, args: List(String)) -> Int
