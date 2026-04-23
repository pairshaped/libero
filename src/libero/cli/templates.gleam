//// Template strings for `libero new` scaffolding.
////
//// Each function returns a file's content as a String. The generated
//// files give a new project a minimal skeleton to build from.

/// Returns gleam.toml content for a new project (the server package).
/// Libero config lives under the [tools.libero] section.
/// `db_deps` is inserted after the existing deps (e.g. pog, sqlight lines).
/// `extra_toml` is appended after the [tools.libero] section (e.g. [tools.marmot]).
pub fn gleam_toml(
  name name: String,
  db_deps db_deps: String,
  extra_toml extra_toml: String,
) -> String {
  "name = \"" <> name <> "\"
version = \"0.1.0\"
target = \"erlang\"

[dependencies]
gleam_stdlib = \">= 0.69.0 and < 1.0.0\"
gleam_erlang = \"~> 1.0\"
gleam_http = \"~> 4.0\"
mist = \"~> 6.0\"
lustre = \"~> 5.6\"
shared = { path = \"shared\" }
libero = \"~> 4.2\"
" <> db_deps <> "
[dev-dependencies]
gleeunit = \"~> 1.0\"

[tools.libero]
port = 8080
" <> extra_toml
}

/// Returns gleam.toml content for the shared package.
/// Target-agnostic so both the Erlang server and JS clients can import
/// messages and types from it.
pub fn shared_gleam_toml() -> String {
  "name = \"shared\"
version = \"0.1.0\"

# No target specified - compiles to both Erlang and JavaScript.

[dependencies]
gleam_stdlib = \">= 0.69.0 and < 1.0.0\"
libero = \"~> 4.2\"

[dev-dependencies]
gleeunit = \"~> 1.0\"
"
}

/// Returns a skeleton messages module.
///
/// Defines the typed RPC boundary between client and server.
/// Add your message types here — libero scans for MsgFromClient
/// and MsgFromServer to generate dispatch and client stubs.
pub fn starter_messages() -> String {
  "/// Define your message types here.
/// Libero scans for MsgFromClient and MsgFromServer to generate
/// dispatch and client stubs.

pub type MsgFromClient {
  Ping
}

pub type MsgFromServer {
  Pong(String)
}
"
}

/// Returns a skeleton handler module.
pub fn starter_handler() -> String {
  "import server/app_error.{type AppError}
import server/shared_state.{type SharedState}
import shared/messages.{type MsgFromClient, type MsgFromServer, Ping, Pong}

pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> Result(#(MsgFromServer, SharedState), AppError) {
  case msg {
    Ping -> Ok(#(Pong(\"pong\"), state))
  }
}
"
}

/// Returns a skeleton SharedState module.
pub fn starter_shared_state() -> String {
  "pub type SharedState {
  SharedState
}

pub fn new() -> SharedState {
  SharedState
}
"
}

/// Returns a skeleton AppError module.
pub fn starter_app_error() -> String {
  "pub type AppError {
  AppError(reason: String)
}
"
}

/// Returns a skeleton test that verifies the handler works.
pub fn starter_test() -> String {
  "import server/handler
import server/shared_state
import shared/messages.{Ping, Pong}
import gleeunit

pub fn main() {
  gleeunit.main()
}

pub fn ping_test() {
  let state = shared_state.new()
  let assert Ok(#(Pong(\"pong\"), _)) =
    handler.update_from_client(msg: Ping, state:)
}
"
}

/// Returns a starter Lustre SPA app module.
pub fn starter_spa(name name: String) -> String {
  "import lustre
import lustre/element
import lustre/element/html

pub fn main() {
  let app = lustre.element(view())
  let assert Ok(_) = lustre.start(app, \"#app\", Nil)
  Nil
}

fn view() -> element.Element(msg) {
  html.div([], [
    html.h1([], [html.text(\"" <> name <> "\")]),
    html.p([], [html.text(\"Edit this file to get started.\")]),
  ])
}
"
}

/// Returns a gleam.toml for a client package.
pub fn client_gleam_toml(
  name name: String,
  target target: String,
  root_package root_package: String,
) -> String {
  "name = \"" <> name <> "\"
version = \"0.1.0\"
target = \"" <> target <> "\"

[dependencies]
gleam_stdlib = \">= 0.69.0 and < 1.0.0\"
shared = { path = \"../../shared\" }
" <> root_package <> " = { path = \"../../\" }
libero = \"~> 4.2\"
" <> case target {
    "javascript" -> "lustre = \"~> 5.6\"\n"
    _ -> ""
  }
}

/// Returns a starter CLI main module.
pub fn starter_cli() -> String {
  "import gleam/io

pub fn main() -> Nil {
  io.println(\"Hello from your Libero app!\")
}
"
}

/// Returns a README.md for a new project.
/// `db_section` is optional database-specific content appended to the end.
pub fn starter_readme(
  name name: String,
  db_section db_section: String,
) -> String {
  "# " <> name <> "

A Libero project.

## Getting started

Build the generated client and server code, then start the server:

```sh
gleam run -m libero -- build
gleam run
```

The server starts on the port configured in `gleam.toml` under
`[tools.libero]` (default 8080).

## Project structure

```
src/server/         Server-side Gleam code (handlers, shared state, etc.)
shared/             Types shared between server and clients (messages, models)
clients/            Client packages (SPA, CLI, etc.)
test/               Tests
```

## Commands

- `gleam run -m libero -- build` generates dispatch, client stubs, and
  other derived code from your message types.
- `gleam run -m libero -- gen` regenerates only the derived code without
  rebuilding everything.
- `gleam run -m libero -- add <name> --target <javascript|erlang>` adds
  a new client package.
- `gleam test` runs the test suite.

## How it works

Define your message types in `shared/src/shared/messages.gleam`. The
`MsgFromClient` type lists every request the client can send; the
`MsgFromServer` type lists every response the server can return.

When you run `libero build`, it reads those types and generates:

- A dispatch module that routes incoming messages to your handler.
- Client stub functions so each client package can call the server
  with typed arguments.

Your handler in `src/server/handler.gleam` pattern-matches on
`MsgFromClient` variants and returns `MsgFromServer` values. Shared
state (database connections, caches, etc.) is threaded through
`SharedState` so every handler call has access to it.
" <> db_section
}
