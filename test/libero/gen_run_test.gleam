//// Integration test through `cli/gen.run`. Verifies codegen writes into
//// the server package at `project_path` and into sibling client packages,
//// with no leak into libero's own src tree.

import gleam/string
import libero/cli/gen
import simplifile

pub fn gen_run_writes_dispatch_inside_project_path_test() {
  let path = "build/.test_gen_run_endpoint"
  setup_endpoint_fixture(path)

  let assert Ok(Nil) = gen.run(project_path: path <> "/server")

  // Endpoint dispatch landed inside the server package.
  let assert Ok(dispatch) =
    simplifile.read(path <> "/server/src/generated/dispatch.gleam")
  let assert True = string.contains(dispatch, "pub type ClientMsg")

  // No leak into libero's own src tree.
  let assert Error(_) = simplifile.read("src/generated/dispatch.gleam")

  let assert Ok(Nil) = simplifile.delete_all([path])
}

pub fn gen_run_writes_atoms_inside_project_path_test() {
  let path = "build/.test_gen_run_atoms"
  setup_endpoint_fixture(path)

  let assert Ok(Nil) = gen.run(project_path: path <> "/server")

  let assert Ok(_) =
    simplifile.read(path <> "/server/src/test_atoms@generated@rpc_atoms.erl")
  let assert Error(_) =
    simplifile.read("src/test_atoms@generated@rpc_atoms.erl")

  let assert Ok(Nil) = simplifile.delete_all([path])
}

pub fn gen_run_writes_main_inside_project_path_test() {
  let path = "build/.test_gen_run_main"
  setup_endpoint_fixture(path)

  let assert Ok(Nil) = gen.run(project_path: path <> "/server")

  // Server entry exists (write_if_missing preserved our fixture's version).
  let assert Ok(_) = simplifile.read(path <> "/server/src/test_main.gleam")
  let assert Error(_) = simplifile.read("src/test_main.gleam")

  let assert Ok(Nil) = simplifile.delete_all([path])
}

pub fn gen_run_writes_client_stubs_inside_project_path_test() {
  let path = "build/.test_gen_run_client"
  setup_endpoint_fixture(path)

  let assert Ok(Nil) = gen.run(project_path: path <> "/server")

  // Client stubs landed in the sibling clients/web/ package.
  let assert Ok(_) =
    simplifile.read(path <> "/clients/web/src/generated/messages.gleam")
  let assert Error(_) =
    simplifile.read("clients/web/src/generated/messages.gleam")

  let assert Ok(Nil) = simplifile.delete_all([path])
}

// -- fixture --
//
// Builds a three-peer monorepo at `path`:
//   <path>/server/   - server package (where libero runs from)
//   <path>/shared/   - cross-target shared types
//   <path>/clients/web/ - JS client
//
// gen.run is called with project_path = <path>/server.

fn setup_endpoint_fixture(path: String) -> Nil {
  let app_name = derive_app_name(path)

  // Create directories
  let assert Ok(Nil) =
    simplifile.create_directory_all(path <> "/shared/src/shared")
  let assert Ok(Nil) = simplifile.create_directory_all(path <> "/server/src")
  let assert Ok(Nil) =
    simplifile.create_directory_all(path <> "/clients/web/src")

  // Server gleam.toml with [tools.libero] config
  write_file(path <> "/server/gleam.toml", endpoint_gleam_toml(app_name))

  // Shared types module — defines the domain type used in handler signatures
  write_file(
    path <> "/shared/src/shared/types.gleam",
    "pub type Item {
  Item(id: Int, name: String)
}
",
  )

  // Server entry — required for codegen's main.gleam discovery
  write_file(
    path <> "/server/src/" <> app_name <> ".gleam",
    "pub fn main() {
  Nil
}
",
  )

  // Server handler context
  write_file(
    path <> "/server/src/handler_context.gleam",
    "pub type HandlerContext {
  HandlerContext
}
",
  )

  // Server handler — the endpoint codegen scans for
  write_file(
    path <> "/server/src/handler.gleam",
    "import handler_context.{type HandlerContext}
import shared/types.{type Item}

pub fn list_items(state state: HandlerContext) -> #(Result(List(Item), Nil), HandlerContext) {
  #(Ok([]), state)
}
",
  )
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

fn endpoint_gleam_toml(app_name: String) -> String {
  "name = \"" <> app_name <> "\"
version = \"0.1.0\"
target = \"erlang\"

[dependencies]
gleam_stdlib = \">= 0.69.0 and < 1.0.0\"
shared = { path = \"../shared\" }

[tools.libero]
port = 8080

[tools.libero.clients.web]
target = \"javascript\"
path = \"../clients/web\"
"
}

fn write_file(path: String, content: String) -> Nil {
  let assert Ok(Nil) = simplifile.write(path, content)
  Nil
}
