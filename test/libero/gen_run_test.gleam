//// Integration test through `cli/gen.run`. Verifies the path-prefix
//// fix from libero-j18s: codegen writes inside `project_path` instead
//// of CWD when the two differ.

import gleam/string
import libero/cli/gen
import simplifile

pub fn gen_run_writes_dispatch_inside_project_path_test() {
  let path = "build/.test_gen_run_endpoint"
  setup_endpoint_fixture(path)

  let assert Ok(Nil) = gen.run(project_path: path)

  // Endpoint dispatch landed at the project-prefixed path.
  let assert Ok(dispatch) =
    simplifile.read(path <> "/src/server/generated/dispatch.gleam")
  let assert True = string.contains(dispatch, "pub type ClientMsg")

  // No leak into libero's own src tree (the bug from libero-j18s).
  let assert Error(_) = simplifile.read("src/server/generated/dispatch.gleam")

  let assert Ok(Nil) = simplifile.delete_all([path])
}

pub fn gen_run_writes_atoms_inside_project_path_test() {
  let path = "build/.test_gen_run_atoms"
  setup_endpoint_fixture(path)

  let assert Ok(Nil) = gen.run(project_path: path)

  let assert Ok(_) =
    simplifile.read(path <> "/src/test_atoms@generated@rpc_atoms.erl")
  let assert Error(_) =
    simplifile.read("src/test_atoms@generated@rpc_atoms.erl")

  let assert Ok(Nil) = simplifile.delete_all([path])
}

pub fn gen_run_writes_main_inside_project_path_test() {
  let path = "build/.test_gen_run_main"
  setup_endpoint_fixture(path)

  let assert Ok(Nil) = gen.run(project_path: path)

  let assert Ok(_) = simplifile.read(path <> "/src/test_main.gleam")
  let assert Error(_) = simplifile.read("src/test_main.gleam")

  let assert Ok(Nil) = simplifile.delete_all([path])
}

pub fn gen_run_writes_client_stubs_inside_project_path_test() {
  let path = "build/.test_gen_run_client"
  setup_endpoint_fixture(path)

  let assert Ok(Nil) = gen.run(project_path: path)

  let assert Ok(_) =
    simplifile.read(path <> "/clients/web/src/generated/messages.gleam")
  let assert Error(_) =
    simplifile.read("clients/web/src/generated/messages.gleam")

  let assert Ok(Nil) = simplifile.delete_all([path])
}

// -- fixture --

fn setup_endpoint_fixture(path: String) -> Nil {
  let app_name = derive_app_name(path)
  let assert Ok(Nil) =
    simplifile.create_directory_all(path <> "/shared/src/shared")
  let assert Ok(Nil) = simplifile.create_directory_all(path <> "/src/server")
  let assert Ok(Nil) =
    simplifile.create_directory_all(path <> "/clients/web/src")

  write_file(path <> "/gleam.toml", endpoint_gleam_toml(app_name))
  write_file(
    path <> "/shared/src/shared/types.gleam",
    "pub type Item {
  Item(id: Int, name: String)
}

pub type ItemError {
  NotFound
}
",
  )
  write_file(
    path <> "/src/server/handler.gleam",
    "import server/handler_context.{type HandlerContext}
import shared/types.{type Item, type ItemError, Item}

pub fn get_item(
  id id: Int,
  state state: HandlerContext,
) -> #(Result(Item, ItemError), HandlerContext) {
  let _ = id
  #(Ok(Item(1, \"hello\")), state)
}
",
  )
  write_file(
    path <> "/src/server/handler_context.gleam",
    "pub type HandlerContext {
  HandlerContext
}
",
  )
  Nil
}

fn derive_app_name(path: String) -> String {
  // Each test uses a distinct app name so the per-test atoms file
  // (named `<app>@generated@rpc_atoms.erl`) doesn't collide across tests.
  case string.split(path, "_") |> list_last() {
    Ok(suffix) -> "test_" <> suffix
    Error(_) -> "test_app"
  }
}

fn list_last(parts: List(String)) -> Result(String, Nil) {
  case parts {
    [] -> Error(Nil)
    [single] -> Ok(single)
    [_, ..rest] -> list_last(rest)
  }
}

fn endpoint_gleam_toml(name: String) -> String {
  "name = \"" <> name <> "\"
version = \"0.1.0\"
target = \"erlang\"

[dependencies]
gleam_stdlib = \">= 0.69.0 and < 1.0.0\"

[tools.libero]
port = 8080

[tools.libero.clients.web]
target = \"javascript\"
"
}

fn write_file(path: String, content: String) -> Nil {
  let assert Ok(Nil) = simplifile.write(path, content)
  Nil
}
