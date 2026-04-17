import gleam/string
import libero/cli/add as cli_add
import simplifile

pub fn add_javascript_client_test() {
  let dir = "test/tmp/add_javascript_client_test"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(Nil) = simplifile.write(dir <> "/libero.toml", "name = \"myapp\"\nport = 8080\n")

  let assert Ok(Nil) =
    cli_add.add_client(project_path: dir, name: "web", target: "javascript")

  let assert Ok(True) = simplifile.is_directory(dir <> "/src/clients/web")
  let assert Ok(True) = simplifile.is_file(dir <> "/src/clients/web/app.gleam")

  let assert Ok(toml) = simplifile.read(dir <> "/libero.toml")
  let assert True = string.contains(toml, "[clients.web]")
  let assert True = string.contains(toml, "target = \"javascript\"")

  let _ = simplifile.delete(dir)
  Nil
}

pub fn add_erlang_client_test() {
  let dir = "test/tmp/add_erlang_client_test"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(Nil) = simplifile.write(dir <> "/libero.toml", "name = \"myapp\"\nport = 8080\n")

  let assert Ok(Nil) =
    cli_add.add_client(project_path: dir, name: "cli", target: "erlang")

  let assert Ok(True) = simplifile.is_directory(dir <> "/src/clients/cli")
  let assert Ok(True) = simplifile.is_file(dir <> "/src/clients/cli/main.gleam")

  let assert Ok(toml) = simplifile.read(dir <> "/libero.toml")
  let assert True = string.contains(toml, "[clients.cli]")
  let assert True = string.contains(toml, "target = \"erlang\"")

  let _ = simplifile.delete(dir)
  Nil
}

pub fn add_skips_existing_app_test() {
  let dir = "test/tmp/add_skips_existing_app_test"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(Nil) = simplifile.write(dir <> "/libero.toml", "name = \"myapp\"\nport = 8080\n")

  let client_dir = dir <> "/src/clients/web"
  let assert Ok(Nil) = simplifile.create_directory_all(client_dir)
  let custom_content = "// custom content, do not overwrite"
  let assert Ok(Nil) = simplifile.write(client_dir <> "/app.gleam", custom_content)

  let assert Ok(Nil) =
    cli_add.add_client(project_path: dir, name: "web", target: "javascript")

  let assert Ok(content) = simplifile.read(client_dir <> "/app.gleam")
  let assert True = content == custom_content

  let _ = simplifile.delete(dir)
  Nil
}
