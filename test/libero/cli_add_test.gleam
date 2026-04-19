import gleam/string
import libero/cli/add as cli_add
import simplifile

fn gleam_toml() -> String {
  "name = \"myapp\"\nversion = \"0.1.0\"\n\n[libero]\nport = 8080\n"
}

pub fn add_javascript_client_test() {
  let dir = "build/.test_cli_add_javascript"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(Nil) = simplifile.write(dir <> "/gleam.toml", gleam_toml())

  let assert Ok(Nil) =
    cli_add.add_client(project_path: dir, name: "web", target: "javascript")

  let assert Ok(True) = simplifile.is_directory(dir <> "/clients/web/src")
  let assert Ok(True) = simplifile.is_file(dir <> "/clients/web/src/app.gleam")
  let assert Ok(True) = simplifile.is_file(dir <> "/clients/web/gleam.toml")

  // Check client gleam.toml has correct target
  let assert Ok(client_toml) = simplifile.read(dir <> "/clients/web/gleam.toml")
  let assert True = string.contains(client_toml, "target = \"javascript\"")
  let assert True = string.contains(client_toml, "lustre")

  // Check root gleam.toml updated
  let assert Ok(toml) = simplifile.read(dir <> "/gleam.toml")
  let assert True = string.contains(toml, "[libero.clients.web]")
  let assert True = string.contains(toml, "target = \"javascript\"")

  let _ = simplifile.delete(dir)
  Nil
}

pub fn add_erlang_client_test() {
  let dir = "build/.test_cli_add_erlang"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(Nil) = simplifile.write(dir <> "/gleam.toml", gleam_toml())

  let assert Ok(Nil) =
    cli_add.add_client(project_path: dir, name: "cli", target: "erlang")

  let assert Ok(True) = simplifile.is_directory(dir <> "/clients/cli/src")
  let assert Ok(True) = simplifile.is_file(dir <> "/clients/cli/src/main.gleam")
  let assert Ok(True) = simplifile.is_file(dir <> "/clients/cli/gleam.toml")

  let assert Ok(toml) = simplifile.read(dir <> "/gleam.toml")
  let assert True = string.contains(toml, "[libero.clients.cli]")

  let _ = simplifile.delete(dir)
  Nil
}

pub fn add_skips_existing_app_test() {
  let dir = "build/.test_cli_add_skips_existing"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(Nil) = simplifile.write(dir <> "/gleam.toml", gleam_toml())

  let client_src = dir <> "/clients/web/src"
  let assert Ok(Nil) = simplifile.create_directory_all(client_src)
  let custom_content = "// custom content, do not overwrite"
  let assert Ok(Nil) = simplifile.write(client_src <> "/app.gleam", custom_content)

  let assert Ok(Nil) =
    cli_add.add_client(project_path: dir, name: "web", target: "javascript")

  let assert Ok(content) = simplifile.read(client_src <> "/app.gleam")
  let assert True = content == custom_content

  let _ = simplifile.delete(dir)
  Nil
}
