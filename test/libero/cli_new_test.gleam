import gleam/string
import libero/cli/new as cli_new
import simplifile

pub fn scaffold_project_test() {
  let dir = "build/.test_cli_new/test_scaffold"
  let _ = simplifile.delete("build/.test_cli_new")

  let assert Ok(Nil) = cli_new.scaffold(name: "my_app", path: dir)

  let assert Ok(True) = simplifile.is_file(dir <> "/gleam.toml")
  let assert Ok(True) = simplifile.is_directory(dir <> "/src/server")
  let assert Ok(True) = simplifile.is_directory(dir <> "/shared/src/shared")

  let assert Ok(gleam_toml) = simplifile.read(dir <> "/gleam.toml")
  let assert True = string.contains(gleam_toml, "name = \"test_scaffold\"")
  let assert True = string.contains(gleam_toml, "target = \"erlang\"")
  let assert True = string.contains(gleam_toml, "[tools.libero]")
  let assert True = string.contains(gleam_toml, "shared = { path = \"shared\"")

  let assert Ok(True) = simplifile.is_file(dir <> "/shared/gleam.toml")
  let assert Ok(True) =
    simplifile.is_file(dir <> "/shared/src/shared/messages.gleam")
  let assert Ok(True) = simplifile.is_file(dir <> "/src/server/handler.gleam")
  let assert Ok(True) =
    simplifile.is_file(dir <> "/src/server/shared_state.gleam")
  let assert Ok(True) = simplifile.is_file(dir <> "/src/server/app_error.gleam")
  let assert Ok(True) =
    simplifile.is_file(dir <> "/test/test_scaffold_test.gleam")

  let _ = simplifile.delete("build/.test_cli_new")
  Nil
}
